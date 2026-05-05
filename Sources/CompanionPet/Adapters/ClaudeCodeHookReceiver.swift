import Foundation

final class ClaudeCodeHookReceiver: @unchecked Sendable {
    private static let supportedEvents = ["PreToolUse", "PostToolUse", "Stop", "Notification"]
    private static let hookPathMarker = "/openpet/hook"

    private let port: Int
    private let host: String
    private let source: String
    private let channel: EventChannel<CompanionEvent>
    private let parser = ClaudeCodeHookParser()
    private let fileManager: FileManager
    private let settingsURL: URL
    private var server: SimpleHTTPServer?

    init(
        port: Int,
        host: String = "127.0.0.1",
        source: String,
        channel: EventChannel<CompanionEvent>,
        fileManager: FileManager = .default,
        settingsURL: URL = URL(filePath: NSHomeDirectory())
            .appending(path: ".claude", directoryHint: .isDirectory)
            .appending(path: "settings.json")
    ) {
        self.port = port
        self.host = host
        self.source = source
        self.channel = channel
        self.fileManager = fileManager
        self.settingsURL = settingsURL
    }

    func start() throws {
        try ensureSettingsDirectoryExists()
        var settings = try loadSettings()
        settings = mergeOpenPetHooks(into: settings)
        try saveSettings(settings)

        let server = SimpleHTTPServer(host: host, port: port) { [weak self] request in
            guard let self else {
                return HTTPResponse.json(statusCode: 503, payload: ["error": "Hook receiver unavailable"])
            }
            return self.handle(request)
        }

        do {
            try server.start()
            self.server = server
        } catch {
            var reverted = try loadSettings()
            reverted = removeOpenPetHooks(from: reverted)
            try? saveSettings(reverted)
            throw error
        }
    }

    func stop() {
        server?.stop()
        server = nil

        guard var settings = try? loadSettings() else {
            return
        }
        settings = removeOpenPetHooks(from: settings)
        try? saveSettings(settings)
    }

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == "POST" else {
            return HTTPResponse.json(statusCode: 405, payload: ["error": "Method not allowed"])
        }
        guard request.target == Self.hookPathMarker else {
            return HTTPResponse.json(statusCode: 404, payload: ["error": "Not found"])
        }

        let events = parser.parse(data: request.body, source: source)
        for event in events {
            channel.send(event)
        }
        return HTTPResponse.json(statusCode: 200, payload: ["ok": "true"])
    }

    private func ensureSettingsDirectoryExists() throws {
        let directory = settingsURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path()) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func loadSettings() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: settingsURL.path()) else {
            return [:]
        }

        let data = try Data(contentsOf: settingsURL)
        guard !data.isEmpty else {
            return [:]
        }

        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func saveSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: [.atomic])
    }

    private func mergeOpenPetHooks(into settings: [String: Any]) -> [String: Any] {
        var result = settings
        var hooks = result["hooks"] as? [String: Any] ?? [:]

        for eventName in Self.supportedEvents {
            var groups = hooks[eventName] as? [[String: Any]] ?? []
            let alreadyConfigured = groups.contains(where: groupContainsOpenPetHook)
            if !alreadyConfigured {
                groups.append([
                    "matcher": "*",
                    "hooks": [[
                        "type": "command",
                        "command": hookCommand(),
                    ]],
                ])
            }
            hooks[eventName] = groups
        }

        result["hooks"] = hooks
        return result
    }

    private func removeOpenPetHooks(from settings: [String: Any]) -> [String: Any] {
        var result = settings
        guard var hooks = result["hooks"] as? [String: Any] else {
            return result
        }

        for eventName in Self.supportedEvents {
            guard let groups = hooks[eventName] as? [[String: Any]] else {
                continue
            }

            let filteredGroups = groups.compactMap { group -> [String: Any]? in
                var updatedGroup = group
                let nestedHooks = (group["hooks"] as? [[String: Any]] ?? []).filter { hook in
                    let command = hook["command"] as? String ?? ""
                    return !command.contains(Self.hookPathMarker)
                }
                guard !nestedHooks.isEmpty else {
                    return nil
                }
                updatedGroup["hooks"] = nestedHooks
                return updatedGroup
            }

            if filteredGroups.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = filteredGroups
            }
        }

        if hooks.isEmpty {
            result.removeValue(forKey: "hooks")
        } else {
            result["hooks"] = hooks
        }
        return result
    }

    private func groupContainsOpenPetHook(_ group: [String: Any]) -> Bool {
        let nestedHooks = group["hooks"] as? [[String: Any]] ?? []
        return nestedHooks.contains { hook in
            let command = hook["command"] as? String ?? ""
            return command.contains(Self.hookPathMarker)
        }
    }

    private func hookCommand() -> String {
        "/usr/bin/curl -s -X POST http://127.0.0.1:\(port)\(Self.hookPathMarker) -H 'Content-Type: application/json' -d @-"
    }
}
