import Foundation
import Testing
@testable import CompanionPet

struct CodexExecJSONParserTests {
    @Test
    func parsesStructuredCodexExecEvents() {
        var parser = CodexExecJSONParser()
        let timestamp = Date(timeIntervalSince1970: 3_000)

        let threadEvents = parser.parse(
            line: #"{"type":"thread.started","thread_id":"thread-1"}"#,
            source: "codex",
            timestamp: timestamp
        )
        #expect(threadEvents.map(\.kind) == [.sessionStarted])

        let turnEvents = parser.parse(
            line: #"{"type":"turn.started"}"#,
            source: "codex",
            timestamp: timestamp
        )
        #expect(turnEvents.map(\.kind) == [.thinkingStarted])

        let toolStart = parser.parse(
            line: #"{"type":"item.started","item":{"id":"item_0","type":"command_execution","command":"ls","status":"in_progress"}}"#,
            source: "codex",
            timestamp: timestamp
        )
        #expect(toolStart.map(\.kind) == [.toolStarted])

        let toolEnd = parser.parse(
            line: #"{"type":"item.completed","item":{"id":"item_0","type":"command_execution","command":"ls","exit_code":0,"status":"completed"}}"#,
            source: "codex",
            timestamp: timestamp
        )
        #expect(toolEnd.map(\.kind) == [.toolFinished])

        let message = parser.parse(
            line: #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"hello"}}"#,
            source: "codex",
            timestamp: timestamp
        )
        #expect(message.map(\.kind) == [.streamStarted, .streamDelta])

        let completed = parser.parse(
            line: #"{"type":"turn.completed","usage":{"output_tokens":12}}"#,
            source: "codex",
            timestamp: timestamp
        )
        #expect(completed.map(\.kind) == [.streamFinished, .sessionEnded])
    }

    @Test
    func emitsErrorForFailedToolItems() {
        var parser = CodexExecJSONParser()
        _ = parser.parse(line: #"{"type":"thread.started","thread_id":"thread-1"}"#, source: "codex")

        let failed = parser.parse(
            line: #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"false","aggregated_output":"failed","status":"failed"}}"#,
            source: "codex"
        )

        #expect(failed.map(\.kind) == [.toolFinished, .error])
    }

    @Test
    func parsesNestedAgentMessageContent() {
        var parser = CodexExecJSONParser()

        let events = parser.parse(
            line: #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","content":[{"type":"output_text","text":"Visible assistant text"}]}}"#,
            source: "codex"
        )

        #expect(events.map(\.kind) == [.streamStarted, .streamDelta])
        #expect(events.last?.payload["text"] == "Visible assistant text")
    }
}
