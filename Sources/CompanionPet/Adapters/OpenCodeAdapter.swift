import AppKit
import Foundation

final class OpenCodeAdapter: CompanionAdapter, @unchecked Sendable {
    let id = "opencode-cli"
    let displayName: String
    let capabilities: Set<AdapterCapability> = [.launchesSessions, .healthChecks]

    private let settings: OpenCodeAdapterSettings
    private let channel = EventChannel<CompanionEvent>()
    private let healthStore = AdapterHealthStore(AdapterHealth.disconnected)
    private let poller: OpenCodeSessionPoller
    private var pollerTask: Task<Void, Never>?

    init(settings: OpenCodeAdapterSettings, poller: OpenCodeSessionPoller? = nil) {
        self.settings = settings
        self.displayName = settings.displayName
        self.poller = poller ?? OpenCodeSessionPoller(executablePath: settings.executablePath)
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
                let events = try await poller.poll(source: id)
                for event in events {
                    channel.send(event)
                }
            } catch {
                await healthStore.set(AdapterHealth(state: .degraded, lastErrorText: error.localizedDescription))
                channel.send(CompanionEvent(source: id, kind: .error, payload: ["message": error.localizedDescription]))
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
