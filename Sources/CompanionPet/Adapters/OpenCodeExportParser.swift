import Foundation

struct OpenCodeExportParser {
    private var seenFirstUser = false
    private var seenUserMessageIDs: Set<String> = []
    private var seenPartIDs: Set<String> = []
    private var startedAssistantMessages: Set<String> = []
    private var streamedAssistantMessages: Set<String> = []
    private var finishedAssistantMessages: Set<String> = []
    private var toolStatusByPartID: [String: String] = [:]

    mutating func parse(exportText: String, source: String) -> [CompanionEvent] {
        guard let jsonStart = exportText.firstIndex(of: "{") else {
            return []
        }

        let jsonText = String(exportText[jsonStart...])
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = root["messages"] as? [[String: Any]] else {
            return []
        }

        var events: [CompanionEvent] = []

        for message in messages {
            guard let info = message["info"] as? [String: Any],
                  let role = info["role"] as? String,
                  let messageID = info["id"] as? String,
                  let sessionID = info["sessionID"] as? String else {
                continue
            }

            let parts = message["parts"] as? [[String: Any]] ?? []
            switch role {
            case "user":
                events.append(contentsOf: parseUserMessage(messageID: messageID, parts: parts, source: source, sessionID: sessionID, timestamp: messageCreatedAt(info: info)))
            case "assistant":
                events.append(contentsOf: parseAssistantMessage(messageID: messageID, info: info, parts: parts, source: source, sessionID: sessionID))
            default:
                continue
            }
        }

        return events
    }

    private mutating func parseUserMessage(messageID: String, parts: [[String: Any]], source: String, sessionID: String, timestamp: Date) -> [CompanionEvent] {
        guard seenUserMessageIDs.insert(messageID).inserted else {
            return []
        }

        let text = joinedText(parts: parts)
        var events: [CompanionEvent] = []

        if !seenFirstUser {
            seenFirstUser = true
            events.append(CompanionEvent(source: source, kind: .sessionStarted, timestamp: timestamp, sessionId: sessionID))
        }

        let payload = text.isEmpty ? [:] : ["text": text]
        events.append(CompanionEvent(source: source, kind: .thinkingStarted, timestamp: timestamp, sessionId: sessionID, payload: payload))

        for part in parts {
            if let partID = part["id"] as? String {
                seenPartIDs.insert(partID)
            }
        }

        return events
    }

    private mutating func parseAssistantMessage(messageID: String, info: [String: Any], parts: [[String: Any]], source: String, sessionID: String) -> [CompanionEvent] {
        var events: [CompanionEvent] = []
        let createdAt = messageCreatedAt(info: info)

        if !startedAssistantMessages.contains(messageID) {
            let reasoning = firstReasoningText(parts: parts)
            let payload = reasoning.flatMap(sanitizeText).map { ["text": $0] } ?? [:]
            events.append(CompanionEvent(source: source, kind: .thinkingStarted, timestamp: createdAt, sessionId: sessionID, payload: payload))
            startedAssistantMessages.insert(messageID)
        }

        for part in parts {
            guard let partID = part["id"] as? String,
                  let partType = part["type"] as? String else {
                continue
            }

            switch partType {
            case "tool":
                events.append(contentsOf: parseToolPart(part: part, partID: partID, source: source, sessionID: sessionID))
            case "text":
                guard seenPartIDs.insert(partID).inserted,
                      let text = sanitizeText(part["text"] as? String),
                      !text.isEmpty else {
                    continue
                }
                if streamedAssistantMessages.insert(messageID).inserted {
                    events.append(CompanionEvent(source: source, kind: .streamStarted, timestamp: partTimestamp(part), sessionId: sessionID))
                }
                events.append(
                    CompanionEvent(
                        source: source,
                        kind: .streamDelta,
                        timestamp: partTimestamp(part),
                        sessionId: sessionID,
                        payload: ["text": text]
                    )
                )
            case "step-finish":
                guard seenPartIDs.insert(partID).inserted else {
                    continue
                }
                let timestamp = partTimestamp(part)
                if streamedAssistantMessages.remove(messageID) != nil {
                    events.append(CompanionEvent(source: source, kind: .streamFinished, timestamp: timestamp, sessionId: sessionID))
                }
                let reason = part["reason"] as? String ?? info["finish"] as? String ?? ""
                if reason == "stop", finishedAssistantMessages.insert(messageID).inserted {
                    events.append(CompanionEvent(source: source, kind: .sessionEnded, timestamp: timestamp, sessionId: sessionID))
                }
            default:
                if let partID = part["id"] as? String {
                    seenPartIDs.insert(partID)
                }
            }
        }

        return events
    }

    private mutating func parseToolPart(part: [String: Any], partID: String, source: String, sessionID: String) -> [CompanionEvent] {
        let state = part["state"] as? [String: Any] ?? [:]
        let status = state["status"] as? String ?? ""
        let previousStatus = toolStatusByPartID[partID]
        let timestamp = partTimestamp(part, state: state)
        let toolName = part["tool"] as? String ?? "tool"
        let command = summarizeToolInput(state["input"])
        var events: [CompanionEvent] = []

        if previousStatus == nil {
            events.append(
                CompanionEvent(
                    source: source,
                    kind: .toolStarted,
                    timestamp: timestamp,
                    sessionId: sessionID,
                    payload: [
                        "command": command ?? toolName,
                        "item_type": toolName,
                    ]
                )
            )
        }

        if status == "completed" || status == "failed" || status == "cancelled" {
            if previousStatus != status {
                let payload = [
                    "command": command ?? toolName,
                    "item_type": toolName,
                    "status": status,
                ]
                events.append(
                    CompanionEvent(
                        source: source,
                        kind: .toolFinished,
                        timestamp: timestamp,
                        sessionId: sessionID,
                        payload: payload
                    )
                )

                if status == "failed", let message = extractToolError(from: state), !message.isEmpty {
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
            }
        }

        toolStatusByPartID[partID] = status
        return events
    }

    private func firstReasoningText(parts: [[String: Any]]) -> String? {
        for part in parts where (part["type"] as? String) == "reasoning" {
            if let text = sanitizeText(part["text"] as? String), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private func joinedText(parts: [[String: Any]]) -> String {
        parts
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { sanitizeText($0["text"] as? String) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func messageCreatedAt(info: [String: Any]) -> Date {
        let time = info["time"] as? [String: Any]
        let raw = numericValue(time?["created"]) ?? 0
        return date(fromMilliseconds: raw)
    }

    private func partTimestamp(_ part: [String: Any], state: [String: Any]? = nil) -> Date {
        if let state, let time = state["time"] as? [String: Any] {
            if let end = numericValue(time["end"]) {
                return date(fromMilliseconds: end)
            }
            if let start = numericValue(time["start"]) {
                return date(fromMilliseconds: start)
            }
        }
        if let time = part["time"] as? [String: Any] {
            if let end = numericValue(time["end"]) {
                return date(fromMilliseconds: end)
            }
            if let start = numericValue(time["start"]) {
                return date(fromMilliseconds: start)
            }
        }
        return .now
    }

    private func date(fromMilliseconds raw: Double) -> Date {
        Date(timeIntervalSince1970: raw / 1000)
    }

    private func numericValue(_ value: Any?) -> Double? {
        switch value {
        case let double as Double:
            return double
        case let int as Int:
            return Double(int)
        case let int64 as Int64:
            return Double(int64)
        default:
            return nil
        }
    }

    private func summarizeToolInput(_ value: Any?) -> String? {
        switch value {
        case let dictionary as [String: Any]:
            for key in ["command", "filePath", "pattern", "question", "prompt", "url", "filePathPattern", "header"] {
                if let value = dictionary[key] as? String, !value.isEmpty {
                    return value
                }
            }
            if let filePaths = dictionary["filePaths"] as? [String], let first = filePaths.first {
                return first
            }
            if let questions = dictionary["questions"] as? [[String: Any]],
               let firstQuestion = questions.first?["question"] as? String,
               !firstQuestion.isEmpty {
                return firstQuestion
            }
            return nil
        default:
            return nil
        }
    }

    private func extractToolError(from state: [String: Any]) -> String? {
        if let output = state["output"] as? String, !output.isEmpty {
            return output
        }
        if let metadata = state["metadata"] as? [String: Any] {
            if let error = metadata["error"] as? String, !error.isEmpty {
                return error
            }
        }
        return nil
    }

    private func sanitizeText(_ text: String?) -> String? {
        guard let text else {
            return nil
        }
        let compact = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else {
            return nil
        }

        // Some local models leak thought-channel markers into the visible text stream.
        let cleaned = compact.replacingOccurrences(of: "<|channel><|channel>\tthought\n", with: "")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
