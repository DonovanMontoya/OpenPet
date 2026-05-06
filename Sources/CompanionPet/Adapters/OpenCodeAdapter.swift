import AppKit
import Foundation
import Darwin

// MARK: - Process locator

/// Abstraction over OS-level process enumeration for finding opencode agent processes.
protocol OpenCodeProcessLocator: Sendable {
    /// Returns PIDs of running processes whose executable basename is "opencode"
    /// and that are not the daemon (i.e., not launched with "serve" as the first argument).
    func agentPIDs() -> [Int32]
}

struct SysctlOpenCodeProcessLocator: OpenCodeProcessLocator {
    func agentPIDs() -> [Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else {
            return []
        }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        var results: [Int32] = []

        for i in 0..<actualCount {
            let proc = procs[i]
            let pid = proc.kp_proc.p_pid
            guard pid > 0 else { continue }

            // Check executable name
            let comm = withUnsafeBytes(of: proc.kp_proc.p_comm) { buf -> String in
                let bytes = buf.bindMemory(to: CChar.self)
                return String(cString: Array(bytes) + [0])
            }
            guard comm == "opencode" else { continue }

            // Filter out the serve daemon by checking argv via KERN_PROCARGS2
            if isServeDaemon(pid: pid) { continue }

            results.append(pid)
        }

        return results
    }

    private func isServeDaemon(pid: Int32) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else {
            return false
        }

        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else {
            return false
        }

        // KERN_PROCARGS2 layout: [argc: Int32][exec_path\0][padding][argv[0]\0][argv[1]\0]...
        guard size > 4 else { return false }
        let argc = buf.withUnsafeBytes { ptr in
            ptr.load(as: Int32.self)
        }
        guard argc >= 2 else { return false }

        // Skip past argc (4 bytes) and the exec path (null-terminated), then find argv[1]
        var offset = 4
        // Skip exec path
        while offset < size, buf[offset] != 0 { offset += 1 }
        // Skip null bytes after exec path
        while offset < size, buf[offset] == 0 { offset += 1 }
        // Skip argv[0] (same as exec path basename typically)
        while offset < size, buf[offset] != 0 { offset += 1 }
        while offset < size, buf[offset] == 0 { offset += 1 }

        // Now at argv[1], if present
        guard offset < size else { return false }
        var argv1Bytes: [UInt8] = []
        while offset < size, buf[offset] != 0 {
            argv1Bytes.append(buf[offset])
            offset += 1
        }
        let argv1 = String(bytes: argv1Bytes, encoding: .utf8) ?? ""
        return argv1 == "serve"
    }
}

// MARK: - Adapter

final class OpenCodeAdapter: CompanionAdapter, @unchecked Sendable {
    let id = "opencode-cli"
    let displayName: String
    let capabilities: Set<AdapterCapability> = [.launchesSessions, .healthChecks]

    private let settings: OpenCodeAdapterSettings
    private let channel = EventChannel<CompanionEvent>()
    private let healthStore = AdapterHealthStore(AdapterHealth.disconnected)
    private let poller: OpenCodeSessionPoller
    private let agentHostResolver: HostResolving
    private let processLocator: OpenCodeProcessLocator
    private var pollerTask: Task<Void, Never>?

    /// Cache of resolved host bindings keyed by session ID.
    private var hostBindingCache: [String: HostBinding] = [:]

    init(
        settings: OpenCodeAdapterSettings,
        poller: OpenCodeSessionPoller? = nil,
        agentHostResolver: HostResolving = AgentHostResolver(),
        processLocator: OpenCodeProcessLocator = SysctlOpenCodeProcessLocator()
    ) {
        self.settings = settings
        self.displayName = settings.displayName
        self.poller = poller ?? OpenCodeSessionPoller(executablePath: settings.executablePath)
        self.agentHostResolver = agentHostResolver
        self.processLocator = processLocator
    }

    func health() async -> AdapterHealth {
        await healthStore.get()
    }

    func events() -> AsyncStream<CompanionEvent> {
        channel.stream()
    }

    func start() async {
        guard FileManager.default.isExecutableFile(atPath: settings.executablePath) else {
            await healthStore.set(AdapterHealth(state: .disconnected, lastErrorText: "OpenCode executable not found."))
            channel.send(
                CompanionEvent(
                    source: id,
                    kind: .adapterDisconnected,
                    payload: ["message": "OpenCode executable not found at \(settings.executablePath)."]
                )
            )
            return
        }

        await healthStore.set(.connected)
        channel.send(CompanionEvent(source: id, kind: .adapterConnected, payload: ["message": "Watching OpenCode activity."]))
        pollerTask?.cancel()
        pollerTask = Task { [weak self] in
            await self?.watchSessions()
        }
    }

    func stop() async {
        pollerTask?.cancel()
        pollerTask = nil
        await healthStore.set(.disconnected)
        channel.finish()
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

    private func watchSessions() async {
        while !Task.isCancelled {
            do {
                let result = try await poller.poll(source: id)
                if let sessionID = result.sessionID, !result.events.isEmpty {
                    let binding = resolvedBinding(for: sessionID)
                    for event in result.events {
                        channel.send(applyHostBinding(event, binding))
                    }
                } else {
                    for event in result.events {
                        channel.send(event)
                    }
                }
            } catch {
                await healthStore.set(AdapterHealth(state: .degraded, lastErrorText: error.localizedDescription))
                channel.send(CompanionEvent(source: id, kind: .error, payload: ["message": error.localizedDescription]))
            }

            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Returns a cached or freshly-resolved host binding for the given session ID.
    private func resolvedBinding(for sessionID: String) -> HostBinding {
        if let cached = hostBindingCache[sessionID] {
            return cached
        }

        // Find a running opencode agent process and resolve its host.
        let pids = processLocator.agentPIDs()
        var binding = HostBinding()

        if let pid = pids.first {
            binding = agentHostResolver.resolveHost(forAgentPID: pid)
            if let cwd = agentHostResolver.currentDirectory(forPID: pid), !cwd.isEmpty {
                binding.cwd = cwd
            }
        }

        hostBindingCache[sessionID] = binding
        return binding
    }

    /// Applies a host binding's fields into the event payload, returning the updated event.
    func applyHostBinding(_ event: CompanionEvent, _ binding: HostBinding) -> CompanionEvent {
        guard !binding.isEmpty else { return event }
        var updated = event
        if let hostBundleID = binding.hostBundleID {
            updated.payload[HostBindingPayloadKey.hostBundleID] = hostBundleID
        }
        if let hostPID = binding.hostPID {
            updated.payload[HostBindingPayloadKey.hostPID] = String(hostPID)
        }
        if let agentPID = binding.agentPID {
            updated.payload[HostBindingPayloadKey.agentPID] = String(agentPID)
        }
        if let tty = binding.tty {
            updated.payload[HostBindingPayloadKey.tty] = tty
        }
        if let cwd = binding.cwd {
            updated.payload[HostBindingPayloadKey.cwd] = cwd
        }
        return updated
    }

    private func quotedShellArgument(_ text: String) -> String {
        "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func quotedAppleScriptString(_ text: String) -> String {
        "\"\(text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
