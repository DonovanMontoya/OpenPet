import AppKit
import Foundation
import Darwin

// MARK: - CodexProcessLocator

/// Locates a running codex process by cwd or falls back to any codex process.
protocol CodexProcessLocator: Sendable {
    func findCodexPID(matchingCwd: String?) -> Int32?
    func findCodexPID(holdingSessionFile fileURL: URL) -> Int32?
}

/// Default implementation that enumerates all processes via sysctl KERN_PROC_ALL.
struct SysctlCodexProcessLocator: CodexProcessLocator, Sendable {
    private let hostResolver: HostResolving

    init(hostResolver: HostResolving) {
        self.hostResolver = hostResolver
    }

    func findCodexPID(matchingCwd: String?) -> Int32? {
        let candidates = codexPIDs()
        guard !candidates.isEmpty else { return nil }

        // If a cwd hint is given, require an exact match. A parent directory match
        // can bind the bubble to an unrelated long-running terminal Codex process.
        if let cwd = matchingCwd {
            for pid in candidates {
                if let procCwd = hostResolver.currentDirectory(forPID: pid),
                   procCwd == cwd {
                    return pid
                }
            }
            return nil
        }

        // Fall back only when the session file gave us no cwd to disambiguate.
        return candidates.first
    }

    func findCodexPID(holdingSessionFile fileURL: URL) -> Int32? {
        let targetPath = fileURL.resolvingSymlinksInPath().path()
        for pid in codexPIDs() where process(pid: pid, hasOpenFileAt: targetPath) {
            return pid
        }
        return nil
    }

    private func codexPIDs() -> [Int32] {
        // Collect all kinfo_proc entries in one sysctl call.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

        // Filter to processes whose short name is "codex".
        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        var candidates: [Int32] = []
        for i in 0..<actualCount {
            let proc = procs[i]
            let pid = proc.kp_proc.p_pid
            // p_comm is a fixed-width C char array — extract as String.
            let name = withUnsafeBytes(of: proc.kp_proc.p_comm) { buf -> String in
                let chars = buf.bindMemory(to: CChar.self)
                return String(cString: chars.baseAddress!)
            }
            if name == "codex" || name.hasPrefix("codex-") {
                candidates.append(pid)
            }
        }

        return candidates
    }

    private func process(pid: Int32, hasOpenFileAt targetPath: String) -> Bool {
        let bytesNeeded = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytesNeeded > 0 else {
            return false
        }

        let fdInfoSize = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytesNeeded) / fdInfoSize)
        let bytesRead = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytesRead > 0 else {
            return false
        }

        for descriptor in descriptors.prefix(Int(bytesRead) / fdInfoSize) where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
            var vnodeInfo = vnode_fdinfowithpath()
            let vnodeBytes = withUnsafeMutablePointer(to: &vnodeInfo) { pointer in
                proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, pointer, Int32(MemoryLayout<vnode_fdinfowithpath>.stride))
            }
            guard vnodeBytes == MemoryLayout<vnode_fdinfowithpath>.stride else {
                continue
            }

            let pathCapacity = MemoryLayout.size(ofValue: vnodeInfo.pvip.vip_path)
            let openPath = withUnsafePointer(to: &vnodeInfo.pvip.vip_path) { pointer -> String in
                pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { cString in
                    String(cString: cString)
                }
            }
            if URL(filePath: openPath).resolvingSymlinksInPath().path() == targetPath {
                return true
            }
        }

        return false
    }
}

struct CodexSessionMetadata: Equatable {
    enum PayloadKey {
        static let originator = "codex_originator"
        static let source = "codex_session_source"
    }

    var id: String?
    var cwd: String?
    var originator: String?
    var source: String?

    var eventPayload: [String: String] {
        var payload: [String: String] = [:]
        if let cwd {
            payload[HostBindingPayloadKey.cwd] = cwd
        }
        if let originator {
            payload[PayloadKey.originator] = originator
        }
        if let source {
            payload[PayloadKey.source] = source
        }
        return payload
    }

    var prefersT3CodeHost: Bool {
        let values = [originator, source]
            .compactMap { $0?.lowercased() }
        return values.contains { value in
            value.contains("t3code") || value.contains("t3_code")
        }
    }

    func merging(_ other: CodexSessionMetadata?) -> CodexSessionMetadata {
        guard let other else {
            return self
        }
        return CodexSessionMetadata(
            id: id ?? other.id,
            cwd: cwd ?? other.cwd,
            originator: originator ?? other.originator,
            source: source ?? other.source
        )
    }

    static func parse(from text: String) -> CodexSessionMetadata {
        var metadata = CodexSessionMetadata()

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(rawLine.utf8)) as? [String: Any] else {
                continue
            }
            let payload = json["payload"] as? [String: Any]
            metadata.id = metadata.id ?? payload?["id"] as? String ?? json["id"] as? String
            metadata.cwd = metadata.cwd ?? payload?["cwd"] as? String ?? json["cwd"] as? String
            metadata.originator = metadata.originator ?? payload?["originator"] as? String ?? payload?[PayloadKey.originator] as? String ?? json["originator"] as? String ?? json[PayloadKey.originator] as? String
            metadata.source = metadata.source ?? payload?["source"] as? String ?? payload?[PayloadKey.source] as? String ?? json["source"] as? String ?? json[PayloadKey.source] as? String

            if metadata.id != nil, metadata.cwd != nil, metadata.originator != nil, metadata.source != nil {
                break
            }
        }

        return metadata
    }

    static func parseFirstLine(at url: URL, maxBytes: Int = 2 * 1024 * 1024) -> CodexSessionMetadata {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return CodexSessionMetadata()
        }
        defer { try? handle.close() }

        var data = Data()
        while data.count < maxBytes {
            let remaining = min(16 * 1024, maxBytes - data.count)
            guard let chunk = try? handle.read(upToCount: remaining), !chunk.isEmpty else {
                break
            }

            if let newline = chunk.firstIndex(of: 0x0A) {
                data.append(chunk[..<newline])
                break
            }

            data.append(chunk)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return CodexSessionMetadata()
        }
        return parse(from: text)
    }
}

// MARK: - AdapterHealthStore

actor AdapterHealthStore {
    private var value: AdapterHealth

    init(_ value: AdapterHealth) {
        self.value = value
    }

    func set(_ newValue: AdapterHealth) {
        value = newValue
    }

    func get() -> AdapterHealth {
        value
    }
}

// MARK: - ProcessRegistry

private actor ProcessRegistry {
    private var processes: [UUID: Process] = [:]
    private var terminated = false

    func add(_ process: Process, for id: UUID) {
        processes[id] = process
    }

    func remove(id: UUID) -> Bool {
        processes.removeValue(forKey: id)
        return terminated
    }

    func stopAll() -> [Process] {
        terminated = true
        let active = Array(processes.values)
        processes.removeAll()
        return active
    }
}

// MARK: - CodexCLIAdapter

final class CodexCLIAdapter: CompanionAdapter, @unchecked Sendable {
    let id = "codex-cli"
    let displayName: String
    let capabilities: Set<AdapterCapability> = [.launchesSessions, .healthChecks]

    private let settings: CodexAdapterSettings
    private let channel = EventChannel<CompanionEvent>()
    private let healthStore = AdapterHealthStore(AdapterHealth.disconnected)
    private let processRegistry = ProcessRegistry()
    private var sessionWatcherTask: Task<Void, Never>?

    // Injected for testability.
    private let hostResolver: HostResolving
    private let processLocator: CodexProcessLocator

    // Cache: session file base name (UUID string) -> resolved binding.
    private let bindingCacheLock = NSLock()
    private var bindingCache: [String: HostBinding] = [:]

    init(
        settings: CodexAdapterSettings,
        agentHostResolver: HostResolving? = nil,
        processLocator: CodexProcessLocator? = nil
    ) {
        self.settings = settings
        self.displayName = settings.displayName
        let resolver = agentHostResolver ?? AgentHostResolver()
        self.hostResolver = resolver
        self.processLocator = processLocator ?? SysctlCodexProcessLocator(hostResolver: resolver)
    }

    func health() async -> AdapterHealth {
        await healthStore.get()
    }

    func events() -> AsyncStream<CompanionEvent> {
        channel.stream()
    }

    func start() async {
        guard FileManager.default.isExecutableFile(atPath: settings.executablePath) else {
            await healthStore.set(AdapterHealth(state: .disconnected, lastErrorText: "Codex executable not found."))
            channel.send(
                CompanionEvent(
                    source: id,
                    kind: .adapterDisconnected,
                    payload: ["message": "Codex executable not found at \(settings.executablePath)."]
                )
            )
            return
        }

        await healthStore.set(.connected)
        channel.send(CompanionEvent(source: id, kind: .adapterConnected, payload: ["message": "Watching Codex activity."]))
        sessionWatcherTask?.cancel()
        sessionWatcherTask = Task { [weak self] in
            await self?.watchCodexSessions()
        }
    }

    func stop() async {
        sessionWatcherTask?.cancel()
        sessionWatcherTask = nil
        let activeProcesses = await processRegistry.stopAll()

        for process in activeProcesses {
            if process.isRunning {
                process.terminate()
            }
        }

        await healthStore.set(.disconnected)
        channel.finish()
    }

    func launchSession(prompt: String, workingDirectory: URL?, model: String?) async throws {
        guard FileManager.default.isExecutableFile(atPath: settings.executablePath) else {
            throw NSError(domain: "CompanionPet.CodexCLIAdapter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Codex executable not found at \(settings.executablePath).",
            ])
        }

        let processID = UUID()
        let process = Process()
        process.executableURL = URL(filePath: settings.executablePath)
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        var arguments = [
            "exec",
            "--json",
            "--skip-git-repo-check",
            "--ephemeral",
        ]
        if let workingDirectory {
            arguments.append(contentsOf: ["-C", workingDirectory.path()])
        }
        if let model, !model.isEmpty {
            arguments.append(contentsOf: ["--model", model])
        }
        arguments.append(prompt)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stderrCollector = StderrCollector()
        process.terminationHandler = { [weak self] process in
            guard let self else {
                return
            }
            Task {
                await self.handleTermination(for: processID, status: process.terminationStatus, stderrCollector: stderrCollector)
            }
        }

        try process.run()

        await processRegistry.add(process, for: processID)

        // Resolve the host that launched codex and stamp every emitted event.
        // tty is nil because stdout is a pipe; cwd comes from the process setup.
        var binding = hostResolver.resolveHost(forAgentPID: process.processIdentifier)
        binding.cwd = workingDirectory?.path(percentEncoded: false)

        Task {
            var parser = CodexExecJSONParser()
            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    let events = parser.parse(line: line, source: self.id)
                    for event in events {
                        self.channel.send(applyHostBinding(event.withModelID(model), binding))
                    }
                }

                let trailingEvents = parser.finishPending(source: self.id)
                for event in trailingEvents {
                    self.channel.send(applyHostBinding(event.withModelID(model), binding))
                }
            } catch {
                self.channel.send(
                    CompanionEvent(
                        source: self.id,
                        kind: .error,
                        payload: ["message": error.localizedDescription]
                    )
                )
            }
        }

        Task {
            for try await line in stderr.fileHandleForReading.bytes.lines {
                await stderrCollector.append(line)
            }
        }
    }

    func openTerminalSession(workingDirectory: URL? = nil) {
        let directory = workingDirectory ?? URL(filePath: settings.workingDirectoryPath)
        let command = "cd \(quotedShellArgument(directory.path())) && \(quotedShellArgument(settings.executablePath))"
        let script = """
        tell application "Terminal"
            activate
            do script \(quotedAppleScriptString(command))
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        appleScript?.executeAndReturnError(nil)
    }

    private func handleTermination(for processID: UUID, status: Int32, stderrCollector: StderrCollector) async {
        let isStopped = await processRegistry.remove(id: processID)

        guard !isStopped else {
            return
        }

        if status != 0 {
            let stderrText = await stderrCollector.value()
            await healthStore.set(AdapterHealth(state: .degraded, lastErrorText: stderrText.isEmpty ? "Codex exited with status \(status)." : stderrText))
            channel.send(
                CompanionEvent(
                    source: id,
                    kind: .error,
                    payload: [
                        "message": stderrText.isEmpty ? "Codex exited with status \(status)." : stderrText,
                    ]
                )
            )
        } else {
            await healthStore.set(.connected)
        }
    }

    private func watchCodexSessions() async {
        var cursor = SessionCursor()

        while !Task.isCancelled {
            do {
                try await pollSessions(at: sessionDirectories(), cursor: &cursor)
            } catch {
                channel.send(
                    CompanionEvent(
                        source: id,
                        kind: .error,
                        payload: ["message": error.localizedDescription]
                    )
                )
            }

            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func sessionDirectories() -> [URL] {
        var directories: [URL] = [
            URL(filePath: NSHomeDirectory())
                .appending(path: ".codex", directoryHint: .isDirectory)
                .appending(path: "sessions", directoryHint: .isDirectory)
        ]
        for path in settings.additionalAgentDirectories where !path.isEmpty {
            directories.append(URL(filePath: path).appending(path: "sessions", directoryHint: .isDirectory))
        }
        return directories
    }

    private func quotedShellArgument(_ text: String) -> String {
        "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func quotedAppleScriptString(_ text: String) -> String {
        "\"\(text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func pollSessions(at directories: [URL], cursor: inout SessionCursor) async throws {
        let fileManager = FileManager.default
        var nestedFiles: [URL] = []
        for directory in directories {
            guard fileManager.fileExists(atPath: directory.path()) else {
                continue
            }

            let sessionFiles = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "jsonl" }

            nestedFiles.append(contentsOf: sessionFiles)
            nestedFiles.append(contentsOf: try directoryEnumerationFiles(root: directory))
        }

        guard let latestFile = try nestedFiles.max(by: { lhs, rhs in
            let lhsDate = try lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let rhsDate = try rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return lhsDate < rhsDate
        }) else {
            return
        }

        if cursor.fileURL != latestFile {
            // Switched to a new session file — resolve a fresh host binding.
            let sessionKey = latestFile.deletingPathExtension().lastPathComponent
            let context = resolveContextForExternalSession(sessionKey: sessionKey, fileURL: latestFile)
            cursor = SessionCursor(
                fileURL: latestFile,
                offset: initialSessionOffset(for: latestFile, previousFileURL: cursor.fileURL),
                parser: CodexSessionJSONLParser(sessionID: context.metadata.id),
                hostBinding: context.hostBinding,
                launchMetadata: context.metadata.eventPayload
            )
        }

        let handle = try FileHandle(forReadingFrom: latestFile)
        defer { try? handle.close() }
        try handle.seek(toOffset: cursor.offset)
        let data = try handle.readToEnd() ?? Data()
        cursor.offset += UInt64(data.count)

        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            return
        }

        let binding = cursor.hostBinding
        let launchMetadata = cursor.launchMetadata
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let events = cursor.parser.parse(line: String(rawLine), source: id)
            for event in events {
                let eventWithMetadata = applyLaunchMetadata(event, launchMetadata)
                if let binding {
                    channel.send(applyHostBinding(eventWithMetadata, binding))
                } else {
                    channel.send(eventWithMetadata)
                }
            }
        }
    }

    /// Resolve (or return cached) a HostBinding for an externally-discovered JSONL session.
    private func resolveContextForExternalSession(sessionKey: String, fileURL: URL) -> CodexSessionContext {
        let metadata = extractSessionMetadata(fileURL: fileURL)

        bindingCacheLock.lock()
        if let cached = bindingCache[sessionKey] {
            bindingCacheLock.unlock()
            return CodexSessionContext(hostBinding: cached, metadata: metadata)
        }
        bindingCacheLock.unlock()

        let sessionCwd = metadata.cwd
        let codexPID = processLocator.findCodexPID(holdingSessionFile: fileURL)
            ?? processLocator.findCodexPID(matchingCwd: sessionCwd)

        if let codexPID {
            var binding = hostResolver.resolveHost(forAgentPID: codexPID)
            // Prefer the cwd we read from the file over whatever proc_pidinfo returns.
            if let cwd = sessionCwd {
                binding.cwd = cwd
            } else {
                binding.cwd = hostResolver.currentDirectory(forPID: codexPID)
            }

            bindingCacheLock.lock()
            bindingCache[sessionKey] = binding
            bindingCacheLock.unlock()
            return CodexSessionContext(hostBinding: binding, metadata: metadata)
        }

        // Historical origin metadata is a fallback only. A session file can be
        // reopened by another host, and the current file owner is more accurate.
        if let binding = hostBindingFromSessionMetadata(metadata) {
            bindingCacheLock.lock()
            bindingCache[sessionKey] = binding
            bindingCacheLock.unlock()
            return CodexSessionContext(hostBinding: binding, metadata: metadata)
        }

        return CodexSessionContext(hostBinding: nil, metadata: metadata)
    }

    /// Read the session header JSONL line to find host-resolution hints.
    private func extractSessionMetadata(fileURL: URL) -> CodexSessionMetadata {
        CodexSessionMetadata.parseFirstLine(at: fileURL)
    }

    private func hostBindingFromSessionMetadata(_ metadata: CodexSessionMetadata) -> HostBinding? {
        guard metadata.prefersT3CodeHost,
              let app = runningApplication(
                bundleIdentifiers: [
                    "com.t3tools.t3code",
                    "com.t3dotgg.code",
                    "com.t3dotgg.code-nightly",
                    "com.t3dotgg.t3code",
                    "com.t3dotgg.t3code-nightly",
                ],
                localizedNames: [
                    "T3 Code",
                    "T3Code",
                    "T3 Code Nightly",
                    "T3Code Nightly",
                    "T3 Code (Nightly)",
                    "T3Code (Nightly)",
                ]
              ) else {
            return nil
        }

        return HostBinding(
            hostBundleID: app.bundleIdentifier,
            hostPID: app.processIdentifier,
            cwd: metadata.cwd
        )
    }

    private func runningApplication(bundleIdentifiers: [String], localizedNames: [String]) -> NSRunningApplication? {
        let normalizedNames = localizedNames.map(normalizedApplicationName)
        return NSWorkspace.shared.runningApplications.first { app in
            guard !app.isTerminated, app.activationPolicy != .prohibited else {
                return false
            }
            if let bundleIdentifier = app.bundleIdentifier,
               bundleIdentifiers.contains(bundleIdentifier) {
                return true
            }
            guard let localizedName = app.localizedName else {
                return false
            }
            return normalizedNames.contains(normalizedApplicationName(localizedName))
        }
    }

    private func normalizedApplicationName(_ name: String) -> String {
        name
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
    }

    private func directoryEnumerationFiles(root: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true, fileURL.pathExtension == "jsonl" {
                files.append(fileURL)
            }
        }
        return files
    }

    private func initialSessionOffset(for fileURL: URL, previousFileURL: URL?) -> UInt64 {
        guard previousFileURL == nil,
              let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return 0
        }
        return UInt64(max(0, size))
    }
}

// MARK: - applyHostBinding

/// Stamps non-nil fields from `binding` into `event.payload` using canonical key names.
func applyHostBinding(_ event: CompanionEvent, _ binding: HostBinding) -> CompanionEvent {
    var event = event
    if let v = binding.hostBundleID { event.payload[HostBindingPayloadKey.hostBundleID] = v }
    if let v = binding.hostPID { event.payload[HostBindingPayloadKey.hostPID] = String(v) }
    if let v = binding.agentPID { event.payload[HostBindingPayloadKey.agentPID] = String(v) }
    if let v = binding.tty { event.payload[HostBindingPayloadKey.tty] = v }
    if let v = binding.cwd { event.payload[HostBindingPayloadKey.cwd] = v }
    return event
}

func applyLaunchMetadata(_ event: CompanionEvent, _ metadata: [String: String]) -> CompanionEvent {
    guard !metadata.isEmpty else {
        return event
    }
    var event = event
    for (key, value) in metadata {
        event.payload[key] = value
    }
    return event
}

// MARK: - SessionCursor

private struct CodexSessionContext {
    var hostBinding: HostBinding?
    var metadata: CodexSessionMetadata
}

private struct SessionCursor {
    var fileURL: URL?
    var offset: UInt64 = 0
    var parser = CodexSessionJSONLParser()
    var hostBinding: HostBinding?
    var launchMetadata: [String: String] = [:]
}

// MARK: - StderrCollector

private actor StderrCollector {
    private var lines: [String] = []

    func append(_ line: String) {
        lines.append(line)
        if lines.count > 12 {
            lines.removeFirst(lines.count - 12)
        }
    }

    func value() -> String {
        lines.joined(separator: "\n")
    }
}
