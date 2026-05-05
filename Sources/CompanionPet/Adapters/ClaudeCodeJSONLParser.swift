import Foundation

struct ClaudeCodeJSONLParser {
    private var seenFirst = false
    private var sessionID: String?
    private var streamOpen = false
    private var activeTools: Set<String> = []

    init(sessionID: String? = nil) {
        self.sessionID = sessionID
    }

    mutating func parse(line: String, source: String, timestamp: Date = .now) -> [CompanionEvent] {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return []
        }

        if sessionID == nil {
            sessionID = extractedSessionID(from: json)
        }

        switch type {
        case "user":
            return parseUser(json: json, source: source, timestamp: timestamp)
        case "assistant":
            return parseAssistant(json: json, source: source, timestamp: timestamp)
        case "summary":
            return []
        default:
            return []
        }
    }

    private mutating func parseUser(json: [String: Any], source: String, timestamp: Date) -> [CompanionEvent] {
        let blocks = contentBlocks(from: json)
        let promptText = extractedText(from: blocks)
        var events: [CompanionEvent] = []
        let isFirstUserLine = !seenFirst

        if isFirstUserLine {
            seenFirst = true
            events.append(
                CompanionEvent(
                    source: source,
                    kind: .sessionStarted,
                    timestamp: timestamp,
                    sessionId: sessionID
                )
            )
        }

        if isFirstUserLine || !promptText.isEmpty {
            events.append(
                CompanionEvent(
                    source: source,
                    kind: .thinkingStarted,
                    timestamp: timestamp,
                    sessionId: sessionID,
                    payload: promptText.isEmpty ? [:] : ["text": promptText]
                )
            )
        }

        for block in blocks {
            guard let dictionary = block as? [String: Any],
                  (dictionary["type"] as? String) == "tool_result" else {
                continue
            }

            let toolID = dictionary["tool_use_id"] as? String ?? dictionary["id"] as? String ?? UUID().uuidString
            activeTools.remove(toolID)

            var payload: [String: String] = [
                "item_type": "tool_result",
                "status": (dictionary["is_error"] as? Bool) == true ? "failed" : "completed",
            ]
            if let toolID = dictionary["tool_use_id"] as? String, !toolID.isEmpty {
                payload["tool_use_id"] = toolID
            }

            events.append(
                CompanionEvent(
                    source: source,
                    kind: .toolFinished,
                    timestamp: timestamp,
                    sessionId: sessionID,
                    payload: payload
                )
            )
        }

        return events
    }

    private mutating func parseAssistant(json: [String: Any], source: String, timestamp: Date) -> [CompanionEvent] {
        let blocks = contentBlocks(from: json)
        let stopReason = extractedStopReason(from: json)

        switch stopReason {
        case "tool_use":
            var events: [CompanionEvent] = []
            for block in blocks {
                guard let dictionary = block as? [String: Any],
                      (dictionary["type"] as? String) == "tool_use" else {
                    continue
                }

                let toolID = dictionary["id"] as? String ?? UUID().uuidString
                guard activeTools.insert(toolID).inserted else {
                    continue
                }

                let name = dictionary["name"] as? String ?? "tool"
                events.append(
                    CompanionEvent(
                        source: source,
                        kind: .toolStarted,
                        timestamp: timestamp,
                        sessionId: sessionID,
                        payload: [
                            "command": name,
                            "item_type": "tool_use",
                        ]
                    )
                )
            }
            return events
        case "end_turn":
            let text = extractedText(from: blocks)
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
            streamOpen = false
            events.append(CompanionEvent(source: source, kind: .streamFinished, timestamp: timestamp, sessionId: sessionID))
            events.append(CompanionEvent(source: source, kind: .sessionEnded, timestamp: timestamp, sessionId: sessionID))
            return events
        case let stopReason? where !stopReason.isEmpty:
            streamOpen = false
            return [CompanionEvent(source: source, kind: .sessionEnded, timestamp: timestamp, sessionId: sessionID)]
        default:
            return []
        }
    }

    private func contentBlocks(from json: [String: Any]) -> [Any] {
        if let content = json["content"] as? [Any] {
            return content
        }
        if let message = json["message"] as? [String: Any], let content = message["content"] as? [Any] {
            return content
        }
        return []
    }

    private func extractedStopReason(from json: [String: Any]) -> String? {
        if let stopReason = json["stop_reason"] as? String {
            return stopReason
        }
        if let message = json["message"] as? [String: Any] {
            return message["stop_reason"] as? String
        }
        return nil
    }

    private func extractedSessionID(from json: [String: Any]) -> String? {
        if let sessionID = json["session_id"] as? String {
            return sessionID
        }
        if let message = json["message"] as? [String: Any] {
            if let sessionID = message["session_id"] as? String {
                return sessionID
            }
            if let id = message["id"] as? String {
                return id
            }
        }
        return json["id"] as? String
    }

    private func extractedText(from value: Any?) -> String {
        switch value {
        case let text as String:
            return text
        case let dictionary as [String: Any]:
            if let type = dictionary["type"] as? String, type == "tool_use" || type == "tool_result" {
                return ""
            }
            for key in ["text", "content", "message"] {
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
}
