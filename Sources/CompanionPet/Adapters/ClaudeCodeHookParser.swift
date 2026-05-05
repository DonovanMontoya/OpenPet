import Foundation

struct ClaudeCodeHookParser {
    func parse(data: Data, source: String, timestamp: Date = .now) -> [CompanionEvent] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return parse(payload: json, source: source, timestamp: timestamp)
    }

    func parse(payload: [String: Any], source: String, timestamp: Date = .now) -> [CompanionEvent] {
        let sessionID = payload["session_id"] as? String ?? payload["sessionId"] as? String ?? payload["agent_id"] as? String
        let eventName = payload["hook_event_name"] as? String ?? payload["hookEventName"] as? String

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
                    payload: ["text": command]
                ),
                CompanionEvent(
                    source: source,
                    kind: .toolStarted,
                    timestamp: timestamp,
                    sessionId: sessionID,
                    payload: [
                        "command": command,
                        "item_type": toolName,
                    ]
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
                    payload: [
                        "command": command,
                        "item_type": toolName,
                        "status": extractedError(from: payload) == nil ? "completed" : "failed",
                    ]
                ),
            ]

            if let message = extractedError(from: payload) {
                events.append(
                    CompanionEvent(
                        source: source,
                        kind: .error,
                        timestamp: timestamp,
                        sessionId: sessionID,
                        payload: ["message": message]
                    )
                )
            }

            return events
        case "Stop":
            return [
                CompanionEvent(source: source, kind: .streamFinished, timestamp: timestamp, sessionId: sessionID),
                CompanionEvent(source: source, kind: .sessionEnded, timestamp: timestamp, sessionId: sessionID),
            ]
        case "Notification":
            guard (payload["notification_type"] as? String) == "waiting_for_input" else {
                return []
            }
            return [CompanionEvent(source: source, kind: .userWaiting, timestamp: timestamp, sessionId: sessionID)]
        case "SubagentStop":
            return [CompanionEvent(source: source, kind: .sessionEnded, timestamp: timestamp, sessionId: sessionID)]
        default:
            return []
        }
    }

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
