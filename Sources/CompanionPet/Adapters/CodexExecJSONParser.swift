import Foundation

struct CodexExecJSONParser {
    private var threadID: String?
    private var streamOpen = false

    mutating func parse(line: String, source: String, timestamp: Date = .now) -> [CompanionEvent] {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return []
        }

        switch type {
        case "thread.started":
            let threadID = json["thread_id"] as? String
            self.threadID = threadID
            return [CompanionEvent(source: source, kind: .sessionStarted, timestamp: timestamp, sessionId: threadID)]
        case "turn.started":
            return [CompanionEvent(source: source, kind: .thinkingStarted, timestamp: timestamp, sessionId: threadID)]
        case "turn.completed", "task_complete":
            return completedSessionEvents(source: source, timestamp: timestamp)
        case "agent_message_delta":
            return streamDeltaEvents(source: source, timestamp: timestamp, text: extractedText(from: json["delta"]))
        case "agent_message":
            return streamMessageEvents(source: source, timestamp: timestamp, text: extractedText(from: json["message"] ?? json["content"]))
        case "item.started":
            return parseItemStarted(json: json, source: source, timestamp: timestamp)
        case "item.completed":
            return parseItemCompleted(json: json, source: source, timestamp: timestamp)
        default:
            return []
        }
    }

    mutating func finishPending(source: String, timestamp: Date = .now) -> [CompanionEvent] {
        completedSessionEvents(source: source, timestamp: timestamp)
    }

    private mutating func parseItemStarted(json: [String: Any], source: String, timestamp: Date) -> [CompanionEvent] {
        guard let item = json["item"] as? [String: Any],
              let itemType = item["type"] as? String else {
            return []
        }

        switch itemType {
        case "command_execution", "mcp_tool_call", "web_search", "file_change", "todo_list":
            return [
                CompanionEvent(
                    source: source,
                    kind: .toolStarted,
                    timestamp: timestamp,
                    sessionId: threadID,
                    payload: [
                        "item_type": itemType,
                        "command": item["command"] as? String ?? "",
                    ]
                ),
            ]
        case "agent_message":
            return streamMessageEvents(source: source, timestamp: timestamp, text: extractedText(from: item["text"] ?? item["message"] ?? item["content"]))
        default:
            return []
        }
    }

    private mutating func parseItemCompleted(json: [String: Any], source: String, timestamp: Date) -> [CompanionEvent] {
        guard let item = json["item"] as? [String: Any],
              let itemType = item["type"] as? String else {
            return []
        }

        switch itemType {
        case "command_execution", "mcp_tool_call", "web_search", "file_change", "todo_list":
            var events = [
                CompanionEvent(
                    source: source,
                    kind: .toolFinished,
                    timestamp: timestamp,
                    sessionId: threadID,
                    payload: [
                        "item_type": itemType,
                        "status": item["status"] as? String ?? "",
                        "command": item["command"] as? String ?? "",
                    ]
                ),
            ]

            if let status = item["status"] as? String, status == "failed" {
                let message = (item["error"] as? [String: Any])?["message"] as? String
                    ?? item["aggregated_output"] as? String
                    ?? "Codex reported a failed tool invocation."
                events.append(
                    CompanionEvent(
                        source: source,
                        kind: .error,
                        timestamp: timestamp,
                        sessionId: threadID,
                        payload: ["message": message]
                    )
                )
            }

            return events
        case "agent_message":
            return streamMessageEvents(source: source, timestamp: timestamp, text: extractedText(from: item["text"] ?? item["message"] ?? item["content"]))
        case "error":
            let message = item["message"] as? String ?? "Codex emitted an error item."
            return [
                CompanionEvent(
                    source: source,
                    kind: .error,
                    timestamp: timestamp,
                    sessionId: threadID,
                    payload: ["message": message]
                ),
            ]
        default:
            return []
        }
    }

    private mutating func streamMessageEvents(source: String, timestamp: Date, text: String?) -> [CompanionEvent] {
        var events: [CompanionEvent] = []
        if !streamOpen {
            streamOpen = true
            events.append(CompanionEvent(source: source, kind: .streamStarted, timestamp: timestamp, sessionId: threadID))
        }
        events.append(
            CompanionEvent(
                source: source,
                kind: .streamDelta,
                timestamp: timestamp,
                sessionId: threadID,
                payload: ["text": text ?? ""]
            )
        )
        return events
    }

    private mutating func streamDeltaEvents(source: String, timestamp: Date, text: String?) -> [CompanionEvent] {
        streamMessageEvents(source: source, timestamp: timestamp, text: text)
    }

    private mutating func completedSessionEvents(source: String, timestamp: Date) -> [CompanionEvent] {
        var events: [CompanionEvent] = []
        if streamOpen {
            streamOpen = false
            events.append(CompanionEvent(source: source, kind: .streamFinished, timestamp: timestamp, sessionId: threadID))
        }
        events.append(CompanionEvent(source: source, kind: .sessionEnded, timestamp: timestamp, sessionId: threadID))
        return events
    }

    private func extractedText(from value: Any?) -> String? {
        switch value {
        case let text as String:
            return text
        case let dictionary as [String: Any]:
            for key in ["text", "message", "content", "delta", "output"] {
                if let text = extractedText(from: dictionary[key]), !text.isEmpty {
                    return text
                }
            }
            return nil
        case let array as [Any]:
            let text = array.compactMap { extractedText(from: $0) }.filter { !$0.isEmpty }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        default:
            return nil
        }
    }
}
