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
    private let settingsURLs: [URL]
    private var server: SimpleHTTPServer?

    static var defaultSettingsURL: URL {
        URL(filePath: NSHomeDirectory())
            .appending(path: ".claude", directoryHint: .isDirectory)
            .appending(path: "settings.json")
    }

    init(
        port: Int,
        host: String = "127.0.0.1",
        source: String,
        channel: EventChannel<CompanionEvent>,
        fileManager: FileManager = .default,
        settingsURLs: [URL]? = nil
    ) {
        self.port = port
        self.host = host
        self.source = source
        self.channel = channel
        self.fileManager = fileManager
        let resolved = settingsURLs ?? [ClaudeCodeHookReceiver.defaultSettingsURL]
        self.settingsURLs = resolved.isEmpty ? [ClaudeCodeHookReceiver.defaultSettingsURL] : resolved
    }

    func start() throws {
        for settingsURL in settingsURLs {
            try ensureSettingsDirectoryExists(for: settingsURL)
            var settings = try loadSettings(at: settingsURL)
            settings = mergeOpenPetHooks(into: settings)
            try saveSettings(settings, to: settingsURL)
        }

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
            for settingsURL in settingsURLs {
                if var reverted = try? loadSettings(at: settingsURL) {
                    reverted = removeOpenPetHooks(from: reverted)
                    try? saveSettings(reverted, to: settingsURL)
                }
            }
            throw error
        }
    }

    func stop() {
        server?.stop()
        server = nil

        for settingsURL in settingsURLs {
            guard var settings = try? loadSettings(at: settingsURL) else {
                continue
            }
            settings = removeOpenPetHooks(from: settings)
            try? saveSettings(settings, to: settingsURL)
        }
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

    private func ensureSettingsDirectoryExists(for settingsURL: URL) throws {
        let directory = settingsURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path()) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func loadSettings(at settingsURL: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: settingsURL.path()) else {
            return [:]
        }

        let data = try Data(contentsOf: settingsURL)
        guard !data.isEmpty else {
            return [:]
        }

        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func saveSettings(_ settings: [String: Any], to settingsURL: URL) throws {
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
        // Wrap in bash to capture shell env vars and merge them into the hook JSON before posting.
        // We avoid jq (not guaranteed to be installed) by prepending openpet_ keys then appending
        // the original payload with its leading '{' stripped: {"openpet_...","<rest-of-original>}.
        // bash parameter expansion handles JSON-escaping without requiring sed or any external tool.
        let url = "http://127.0.0.1:\(port)\(Self.hookPathMarker)"
        // Concatenate two raw-string segments so the port-interpolated URL doesn't break raw-string
        // delimiter detection (a bare "# inside a #"..."# raw string would end it early).
        // swiftlint:disable:next line_length
        let prefix = #"/bin/bash -c 'p=$(cat); p=${p:-\{\}}; b=${__CFBundleIdentifier:-}; b="${b//\\/\\\\}"; b="${b//\"/\\\"}"; pp="${PPID:-}"; tp="${TERM_PROGRAM:-}"; tt=$(tty 2>/dev/null); printf "{\"openpet_host_bundle_id\":\"%s\",\"openpet_host_ppid\":\"%s\",\"openpet_term_program\":\"%s\",\"openpet_tty\":\"%s\",%s" "$b" "$pp" "$tp" "$tt" "${p#\{}" | /usr/bin/curl -s -X POST "#
        let suffix = #" -H "Content-Type: application/json" -d @-'"#
        return prefix + url + suffix
    }
}
