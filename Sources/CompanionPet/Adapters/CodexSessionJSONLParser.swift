import Foundation

struct CodexSessionJSONLParser {
    private var sessionID: String?
    private var streamOpen = false
    private var activeTools: Set<String> = []

    mutating func parse(line: String, source: String, timestamp: Date = .now) -> [CompanionEvent] {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return []
        }

        guard let type = json["type"] as? String else {
            if sessionID == nil, let id = json["id"] as? String {
                sessionID = id
                return [
                    CompanionEvent(
                        source: source,
                        kind: .sessionStarted,
                        timestamp: parsedTimestamp(from: json["timestamp"]) ?? timestamp,
                        sessionId: id
                    ),
                ]
            }
            return []
        }

        switch type {
        case "session_meta":
            return parseSessionMeta(json: json, source: source, timestamp: timestamp)
        case "event_msg":
            return parseEventMessage(json: json, source: source, timestamp: timestamp)
        case "response_item":
            return parseResponseItem(json: json, source: source, timestamp: timestamp)
        case "turn_context":
            return []
        case "message":
            return parseMessage(json: json, source: source, timestamp: timestamp)
        case "local_shell_call":
            return parseLocalShellCall(json: json, source: source, timestamp: timestamp)
        case "function_call_output":
            return parseFunctionCallOutput(json: json, source: source, timestamp: timestamp)
        case "task_complete":
            return completeStreamIfNeeded(source: source, timestamp: timestamp) + [
                CompanionEvent(source: source, kind: .sessionEnded, timestamp: timestamp, sessionId: sessionID),
            ]
        default:
            return []
        }
    }

    private mutating func parseSessionMeta(json: [String: Any], source: String, timestamp: Date) -> [CompanionEvent] {
        guard let payload = json["payload"] as? [String: Any],
              let id = payload["id"] as? String
        else {
            return []
        }
        sessionID = id
        return [
            CompanionEvent(
                source: source,
                kind: .sessionStarted,
                timestamp: parsedTimestamp(from: payload["timestamp"]) ?? parsedTimestamp(from: json["timestamp"]) ?? timestamp,
                sessionId: id
            ),
        ]
    }

    private mutating func parseEventMessage(json: [String: Any], source: String, timestamp: Date) -> [CompanionEvent] {
        guard let payload = json["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String else {
            return []
        }

        switch payloadType {
        case "task_started", "user_message":
            let text = extractedText(from: payload)
            return [
                CompanionEvent(
                    source: source,
                    kind: .thinkingStarted,
                    timestamp: timestamp,
                    sessionId: sessionID,
                    payload: text.isEmpty ? [:] : ["text": text]
                ),
            ]
        case "agent_message":
            let text = extractedText(from: payload)
            return streamMessageEvents(source: source, timestamp: timestamp, text: text)
        case "task_complete":
            return completeStreamIfNeeded(source: source, timestamp: timestamp) + [
                CompanionEvent(source: source, kind: .sessionEnded, timestamp: timestamp, sessionId: sessionID),
            ]
        default:
            return []
        }
    }

    private mutating func parseResponseItem(json: [String: Any], source: String, timestamp: Date) -> [CompanionEvent] {
        guard let payload = json["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String else {
            return []
        }

        switch payloadType {
        case "message":
            return parseMessage(json: payload, source: source, timestamp: timestamp)
        case "function_call", "custom_tool_call":
            return parseToolCallPayload(payload, source: source, timestamp: timestamp)
        case "function_call_output":
            return parseFunctionCallOutput(json: payload, source: source, timestamp: timestamp)
        default:
            return []
        }
    }

    private mutating func parseMessage(json: [String: Any], source: String, timestamp: Date) -> [CompanionEvent] {
        guard let role = json["role"] as? String else {
            return []
        }

        let text = extractedText(from: json["content"])

        switch role {
        case "assistant":
            return streamMessageEvents(source: source, timestamp: timestamp, text: text)
        case "user":
            return [
                CompanionEvent(
                    source: source,
                    kind: .thinkingStarted,
                    timestamp: timestamp,
                    sessionId: sessionID,
                    payload: ["text": text]
                ),
            ]
        default:
            return []
        }
    }

    private mutating func parseToolCallPayload(_ payload: [String: Any], source: String, timestamp: Date) -> [CompanionEvent] {
        let id = payload["call_id"] as? String ?? payload["id"] as? String ?? UUID().uuidString
        let name = payload["name"] as? String ?? payload["tool_name"] as? String ?? "tool"
        guard activeTools.insert(id).inserted else {
            return []
        }
        return [
            CompanionEvent(
                source: source,
                kind: .toolStarted,
                timestamp: timestamp,
                sessionId: sessionID,
                payload: ["command": name, "item_type": "tool_call"]
            ),
        ]
    }

    private mutating func parseLocalShellCall(json: [String: Any], source: String, timestamp: Date) -> [CompanionEvent] {
        guard let id = json["id"] as? String else {
            return []
        }
        let status = json["status"] as? String ?? ""
        let action = json["action"] as? [String: Any]
        let commandParts = action?["command"] as? [String] ?? []
        let command = commandParts.joined(separator: " ")
        let displayCommand = displayCommand(from: commandParts)

        switch status {
        case "in_progress", "started":
            guard activeTools.insert(id).inserted else { return [] }
            return [
                CompanionEvent(
                    source: source,
                    kind: .toolStarted,
                    timestamp: timestamp,
                    sessionId: sessionID,
                    payload: localShellPayload(command: command, displayCommand: displayCommand)
                ),
            ]
        case "completed", "failed", "cancelled":
            let startedEvent: [CompanionEvent]
            if activeTools.insert(id).inserted {
                startedEvent = [
                    CompanionEvent(
                        source: source,
                        kind: .toolStarted,
                        timestamp: timestamp,
                        sessionId: sessionID,
                        payload: localShellPayload(command: command, displayCommand: displayCommand)
                    ),
                ]
            } else {
                startedEvent = []
            }
            activeTools.remove(id)
            return startedEvent + [
                CompanionEvent(
                    source: source,
                    kind: .toolFinished,
                    timestamp: timestamp,
                    sessionId: sessionID,
                    payload: localShellPayload(command: command, displayCommand: displayCommand, status: status)
                ),
            ]
        default:
            return []
        }
    }

    private mutating func parseFunctionCallOutput(json: [String: Any], source: String, timestamp: Date) -> [CompanionEvent] {
        if let callID = json["call_id"] as? String {
            activeTools.remove(callID)
        }

        guard let output = json["output"] as? String,
              let data = output.data(using: .utf8),
              let nested = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [
                CompanionEvent(
                    source: source,
                    kind: .toolFinished,
                    timestamp: timestamp,
                    sessionId: sessionID,
                    payload: ["status": "completed", "item_type": "tool_call"]
                ),
            ]
        }

        let exitCode = (nested["metadata"] as? [String: Any])?["exit_code"] as? Int ?? 0
        var events = [
            CompanionEvent(
                source: source,
                kind: .toolFinished,
                timestamp: timestamp,
                sessionId: sessionID,
                payload: [
                    "status": exitCode == 0 ? "completed" : "failed",
                    "item_type": "tool_call",
                ]
            ),
        ]
        guard exitCode != 0 else {
            return events
        }

        let message = nested["output"] as? String ?? "Codex command failed."
        events.append(
            CompanionEvent(
                source: source,
                kind: .error,
                timestamp: timestamp,
                sessionId: sessionID,
                payload: ["message": message]
            )
        )
        return events
    }

    private mutating func streamMessageEvents(source: String, timestamp: Date, text: String) -> [CompanionEvent] {
        var events: [CompanionEvent] = []
        if !streamOpen {
            streamOpen = true
            events.append(CompanionEvent(source: source, kind: .streamStarted, timestamp: timestamp, sessionId: sessionID))
        }
        if !text.isEmpty {
            events.append(
                CompanionEvent(
                    source: source,
                    kind: .streamDelta,
                    timestamp: timestamp,
                    sessionId: sessionID,
                    payload: ["text": text]
                )
            )
        }
        return events
    }

    private mutating func completeStreamIfNeeded(source: String, timestamp: Date) -> [CompanionEvent] {
        guard streamOpen else {
            return []
        }
        streamOpen = false
        return [CompanionEvent(source: source, kind: .streamFinished, timestamp: timestamp, sessionId: sessionID)]
    }

    private func parsedTimestamp(from value: Any?) -> Date? {
        guard let raw = value as? String else {
            return nil
        }
        return ISO8601DateFormatter().date(from: raw)
    }

    private func extractedText(from value: Any?) -> String {
        switch value {
        case let text as String:
            return text
        case let dictionary as [String: Any]:
            for key in ["text", "message", "content", "delta", "output"] {
                let text = extractedText(from: dictionary[key])
                if !text.isEmpty {
                    return text
                }
            }
            return ""
        case let array as [Any]:
            return array
                .map { extractedText(from: $0) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        default:
            return ""
        }
    }

    private func localShellPayload(command: String, displayCommand: String, status: String? = nil) -> [String: String] {
        var payload = [
            "command": command,
            "display_command": displayCommand,
            "item_type": "local_shell_call",
        ]
        if let status {
            payload["status"] = status
        }
        return payload
    }

    private func displayCommand(from commandParts: [String]) -> String {
        guard commandParts.count >= 3,
              ["bash", "sh", "zsh"].contains(commandParts[0]),
              commandParts[1] == "-lc" || commandParts[1] == "-c" else {
            return commandParts.joined(separator: " ")
        }
        return commandParts.dropFirst(2).joined(separator: " ")
    }
}
