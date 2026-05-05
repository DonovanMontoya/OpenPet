import Foundation
import Testing
@testable import CompanionPet

struct ClaudeCodeJSONLParserTests {
    @Test
    func parsesFirstUserLineAsSessionStartAndThinking() {
        var parser = ClaudeCodeJSONLParser(sessionID: "session-1")

        let events = parser.parse(
            line: #"{"type":"user","content":[{"type":"text","text":"Review this diff"}]}"#,
            source: "claude-code"
        )

        #expect(events.map(\.kind) == [.sessionStarted, .thinkingStarted])
        #expect(events.last?.payload["text"] == "Review this diff")
    }

    @Test
    func parsesToolUseAndToolResultLines() {
        var parser = ClaudeCodeJSONLParser(sessionID: "session-1")
        _ = parser.parse(line: #"{"type":"user","content":[{"type":"text","text":"Run tests"}]}"#, source: "claude-code")

        let toolStart = parser.parse(
            line: #"{"type":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"swift test"}}]}"#,
            source: "claude-code"
        )
        #expect(toolStart.map(\.kind) == [.toolStarted])
        #expect(toolStart.first?.payload["command"] == "Bash")

        let toolFinish = parser.parse(
            line: #"{"type":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","content":"ok"}]}"#,
            source: "claude-code"
        )
        #expect(toolFinish.map(\.kind).contains(.toolFinished))
    }

    @Test
    func parsesEndTurnAsReplyLifecycle() {
        var parser = ClaudeCodeJSONLParser(sessionID: "session-1")

        let events = parser.parse(
            line: #"{"type":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"All done."}]}"#,
            source: "claude-code"
        )

        #expect(events.map(\.kind) == [.streamStarted, .streamDelta, .streamFinished, .sessionEnded])
        #expect(events.first(where: { $0.kind == .streamDelta })?.payload["text"] == "All done.")
    }

    @Test
    func ignoresSummaryLines() {
        var parser = ClaudeCodeJSONLParser(sessionID: "session-1")
        let events = parser.parse(line: #"{"type":"summary","summary":"ignored"}"#, source: "claude-code")
        #expect(events.isEmpty)
    }
}
