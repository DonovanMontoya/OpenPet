import Foundation

// MARK: - Session lookup protocol (injectable for tests)

protocol ClaudeSessionLookup: Sendable {
    func info(forSessionID sessionID: String) -> (pid: Int32, cwd: String)?
}

struct DefaultClaudeSessionLookup: ClaudeSessionLookup {
    private let sessionsDirectory: URL

    init(sessionsDirectory: URL? = nil) {
        self.sessionsDirectory = sessionsDirectory ?? URL(filePath: NSHomeDirectory())
            .appending(path: ".claude", directoryHint: .isDirectory)
            .appending(path: "sessions", directoryHint: .isDirectory)
    }

    func info(forSessionID sessionID: String) -> (pid: Int32, cwd: String)? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }
            // Match on sessionId field inside the JSON
            let storedID = json["sessionId"] as? String ?? json["session_id"] as? String
            guard storedID == sessionID else {
                continue
            }
            // The filename stem is the PID
            if let pid = Int32(file.deletingPathExtension().lastPathComponent),
               let cwd = json["cwd"] as? String, !cwd.isEmpty {
                return (pid: pid, cwd: cwd)
            }
        }
        return nil
    }
}

// MARK: - Parser

struct ClaudeCodeHookParser {
    private let sessionLookup: ClaudeSessionLookup
    private let hostResolver: AgentHostResolver

    init(
        sessionLookup: ClaudeSessionLookup = DefaultClaudeSessionLookup(),
        hostResolver: AgentHostResolver = AgentHostResolver()
    ) {
        self.sessionLookup = sessionLookup
        self.hostResolver = hostResolver
    }

    func parse(data: Data, source: String, timestamp: Date = .now) -> [CompanionEvent] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return parse(payload: json, source: source, timestamp: timestamp)
    }

    func parse(payload: [String: Any], source: String, timestamp: Date = .now) -> [CompanionEvent] {
        let sessionID = payload["session_id"] as? String ?? payload["sessionId"] as? String ?? payload["agent_id"] as? String
        let eventName = payload["hook_event_name"] as? String ?? payload["hookEventName"] as? String

        let hostPayload = resolveHostPayload(from: payload, sessionID: sessionID)

        switch eventName {
        case "PreToolUse":
            let toolName = payload["tool_name"] as? String ?? "Tool"
            let command = extractedCommand(from: payload["tool_input"]) ?? toolName
            return [
                CompanionEvent(
                    source: source,
                    kind: .thinkingStarted,
                    timestamp: timestamp,
                    sessionId: sessionID,
                    payload: hostPayload.merging(["text": command]) { _, new in new }
                ),
                CompanionEvent(
                    source: source,
                    kind: .toolStarted,
                    timestamp: timestamp,
                    sessionId: sessionID,
                    payload: hostPayload.merging([
                        "command": command,
                        "item_type": toolName,
                    ]) { _, new in new }
                ),
            ]
        case "PostToolUse", "PostToolUseFailure":
            let toolName = payload["tool_name"] as? String ?? "Tool"
            let command = extractedCommand(from: payload["tool_input"]) ?? toolName
            var events = [
                CompanionEvent(
                    source: source,
                    kind: .toolFinished,
                    timestamp: timestamp,
                    sessionId: sessionID,
                    payload: hostPayload.merging([
                        "command": command,
                        "item_type": toolName,
                        "status": extractedError(from: payload) == nil ? "completed" : "failed",
                    ]) { _, new in new }
                ),
            ]

            if let message = extractedError(from: payload) {
                events.append(
                    CompanionEvent(
                        source: source,
                        kind: .error,
                        timestamp: timestamp,
                        sessionId: sessionID,
                        payload: hostPayload.merging(["message": message]) { _, new in new }
                    )
                )
            }

            return events
        case "Stop":
            return [
                CompanionEvent(source: source, kind: .streamFinished, timestamp: timestamp, sessionId: sessionID, payload: hostPayload),
                CompanionEvent(source: source, kind: .sessionEnded, timestamp: timestamp, sessionId: sessionID, payload: hostPayload),
            ]
        case "Notification":
            guard (payload["notification_type"] as? String) == "waiting_for_input" else {
                return []
            }
            return [CompanionEvent(source: source, kind: .userWaiting, timestamp: timestamp, sessionId: sessionID, payload: hostPayload)]
        case "SubagentStop":
            return [CompanionEvent(source: source, kind: .sessionEnded, timestamp: timestamp, sessionId: sessionID, payload: hostPayload)]
        default:
            return []
        }
    }

    // MARK: - Host binding resolution

    private func resolveHostPayload(from payload: [String: Any], sessionID: String?) -> [String: String] {
        var result: [String: String] = [:]

        // Collect env-var hints forwarded by the hook command wrapper
        let envBundleID = nonEmpty(payload["openpet_host_bundle_id"] as? String)
        let envPPID = nonEmpty(payload["openpet_host_ppid"] as? String)
        let envTTY = nonEmpty(payload["openpet_tty"] as? String)

        // Apply tty from env — direct and reliable
        if let tty = envTTY {
            result[HostBindingPayloadKey.tty] = tty
        }

        // Look up session file to get agent PID + cwd
        var agentPID: Int32?
        if let sid = sessionID, let info = sessionLookup.info(forSessionID: sid) {
            agentPID = info.pid
            result[HostBindingPayloadKey.agentPID] = String(info.pid)
            result[HostBindingPayloadKey.cwd] = info.cwd
        }

        // Walk the process tree from agent PID to find the GUI host
        // Resolver result is authoritative: it inspects the live ppid tree rather than
        // relying on env vars that may be inherited from an unrelated ancestor.
        if let pid = agentPID {
            let resolved = hostResolver.resolveHost(forAgentPID: pid)
            if let hostPID = resolved.hostPID {
                result[HostBindingPayloadKey.hostPID] = String(hostPID)
            }
            if let bundleID = resolved.hostBundleID {
                result[HostBindingPayloadKey.hostBundleID] = bundleID
            }
        }

        // Fall back to env-var bundle id only if the resolver did not produce one
        if result[HostBindingPayloadKey.hostBundleID] == nil, let b = envBundleID {
            result[HostBindingPayloadKey.hostBundleID] = b
        }

        // Fall back to env PPID as host_pid if resolver gave nothing
        if result[HostBindingPayloadKey.hostPID] == nil, let pp = envPPID {
            result[HostBindingPayloadKey.hostPID] = pp
        }

        return result
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    // MARK: - Helpers

    private func extractedCommand(from value: Any?) -> String? {
        switch value {
        case let dictionary as [String: Any]:
            if let command = dictionary["command"] as? String, !command.isEmpty {
                return command
            }
            if let commands = dictionary["command"] as? [String], !commands.isEmpty {
                return commands.joined(separator: " ")
            }
            if let filePath = dictionary["file_path"] as? String, !filePath.isEmpty {
                return filePath
            }
            return nil
        default:
            return nil
        }
    }

    private func extractedError(from payload: [String: Any]) -> String? {
        for key in ["error", "stderr", "message"] {
            if let text = extractedString(from: payload[key]), !text.isEmpty {
                return text
            }
        }
        for key in ["tool_response", "tool_result", "result"] {
            if let nested = payload[key] as? [String: Any], let text = extractedError(from: nested) {
                return text
            }
        }
        return nil
    }

    private func extractedString(from value: Any?) -> String? {
        switch value {
        case let text as String:
            return text
        case let dictionary as [String: Any]:
            for key in ["message", "error", "text"] {
                if let text = extractedString(from: dictionary[key]), !text.isEmpty {
                    return text
                }
            }
            return nil
        default:
            return nil
        }
    }
}
