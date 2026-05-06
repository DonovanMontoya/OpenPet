import AppKit
import Foundation

final class ClaudeCodeAdapter: CompanionAdapter, @unchecked Sendable {
    let id = "claude-code"
    let displayName: String
    let capabilities: Set<AdapterCapability> = [.launchesSessions, .healthChecks]

    private let settings: ClaudeCodeAdapterSettings
    private let channel = EventChannel<CompanionEvent>()
    private let healthStore = AdapterHealthStore(AdapterHealth.disconnected)
    private let poller: ClaudeCodeSessionPoller
    private var hookReceiver: ClaudeCodeHookReceiver?
    private var pollerTask: Task<Void, Never>?

    init(
        settings: ClaudeCodeAdapterSettings,
        poller: ClaudeCodeSessionPoller? = nil,
        hookReceiver: ClaudeCodeHookReceiver? = nil
    ) {
        self.settings = settings
        self.displayName = settings.displayName
        let sessionRoots = Self.sessionRootDirectories(for: settings)
        self.poller = poller ?? ClaudeCodeSessionPoller(rootDirectories: sessionRoots)
        self.hookReceiver = hookReceiver

        if self.hookReceiver == nil, settings.autoConfigureHooks {
            self.hookReceiver = ClaudeCodeHookReceiver(
                port: settings.hookListenerPort,
                source: id,
                channel: channel,
                settingsURLs: Self.settingsURLs(for: settings)
            )
        }
    }

    private static func sessionRootDirectories(for settings: ClaudeCodeAdapterSettings) -> [URL] {
        var roots: [URL] = [ClaudeCodeSessionPoller.defaultRootDirectory]
        for path in settings.additionalAgentDirectories where !path.isEmpty {
            roots.append(URL(filePath: path).appending(path: "projects", directoryHint: .isDirectory))
        }
        return roots
    }

    private static func settingsURLs(for settings: ClaudeCodeAdapterSettings) -> [URL] {
        var urls: [URL] = [ClaudeCodeHookReceiver.defaultSettingsURL]
        for path in settings.additionalAgentDirectories where !path.isEmpty {
            urls.append(URL(filePath: path).appending(path: "settings.json"))
        }
        return urls
    }

    func health() async -> AdapterHealth {
        await healthStore.get()
    }

    func events() -> AsyncStream<CompanionEvent> {
        channel.stream()
    }

    func start() async {
        guard FileManager.default.isExecutableFile(atPath: settings.executablePath) else {
            await healthStore.set(AdapterHealth(state: .disconnected, lastErrorText: "Claude executable not found."))
            channel.send(
                CompanionEvent(
                    source: id,
                    kind: .adapterDisconnected,
                    payload: ["message": "Claude executable not found at \(settings.executablePath)."]
                )
            )
            return
        }

        await healthStore.set(.connected)
        channel.send(CompanionEvent(source: id, kind: .adapterConnected, payload: ["message": "Watching Claude Code activity."]))

        pollerTask?.cancel()
        pollerTask = Task { [weak self] in
            await self?.watchSessions()
        }

        do {
            try hookReceiver?.start()
        } catch {
            await healthStore.set(AdapterHealth(state: .degraded, lastErrorText: error.localizedDescription))
            channel.send(
                CompanionEvent(
                    source: id,
                    kind: .error,
                    payload: ["message": error.localizedDescription]
                )
            )
        }
    }

    func stop() async {
        pollerTask?.cancel()
        pollerTask = nil
        hookReceiver?.stop()
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
                let events = try await poller.poll(source: id)
                for event in events {
                    channel.send(event)
                }
            } catch {
                await healthStore.set(AdapterHealth(state: .degraded, lastErrorText: error.localizedDescription))
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

    private func quotedShellArgument(_ text: String) -> String {
        "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func quotedAppleScriptString(_ text: String) -> String {
        "\"\(text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
