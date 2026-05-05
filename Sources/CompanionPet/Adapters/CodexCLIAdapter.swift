import Foundation

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

final class CodexCLIAdapter: CompanionAdapter, @unchecked Sendable {
    let id = "codex-cli"
    let displayName: String
    let capabilities: Set<AdapterCapability> = [.launchesSessions, .healthChecks]

    private let settings: CodexAdapterSettings
    private let channel = EventChannel<CompanionEvent>()
    private let healthStore = AdapterHealthStore(AdapterHealth.disconnected)
    private let processRegistry = ProcessRegistry()
    private var sessionWatcherTask: Task<Void, Never>?

    init(settings: CodexAdapterSettings) {
        self.settings = settings
        self.displayName = settings.displayName
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

        Task {
            var parser = CodexExecJSONParser()
            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    let events = parser.parse(line: line, source: self.id)
                    for event in events {
                        self.channel.send(event.withModelID(model))
                    }
                }

                let trailingEvents = parser.finishPending(source: self.id)
                for event in trailingEvents {
                    self.channel.send(event.withModelID(model))
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
        let sessionsDirectory = URL(filePath: NSHomeDirectory())
            .appending(path: ".codex", directoryHint: .isDirectory)
            .appending(path: "sessions", directoryHint: .isDirectory)

        var cursor = SessionCursor()

        while !Task.isCancelled {
            do {
                try await pollSessions(at: sessionsDirectory, cursor: &cursor)
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

    private func pollSessions(at directory: URL, cursor: inout SessionCursor) async throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path()) else {
            return
        }

        let sessionFiles = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "jsonl" }

        let nestedFiles = try sessionFiles + directoryEnumerationFiles(root: directory)
        guard let latestFile = try nestedFiles.max(by: { lhs, rhs in
            let lhsDate = try lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let rhsDate = try rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return lhsDate < rhsDate
        }) else {
            return
        }

        if cursor.fileURL != latestFile {
            cursor = SessionCursor(
                fileURL: latestFile,
                offset: initialSessionOffset(for: latestFile, previousFileURL: cursor.fileURL),
                parser: CodexSessionJSONLParser()
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

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let events = cursor.parser.parse(line: String(rawLine), source: id)
            for event in events {
                channel.send(event)
            }
        }
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

private struct SessionCursor {
    var fileURL: URL?
    var offset: UInt64 = 0
    var parser = CodexSessionJSONLParser()
}

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
