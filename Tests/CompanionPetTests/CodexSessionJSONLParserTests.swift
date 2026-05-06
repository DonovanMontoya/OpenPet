import Foundation
import Testing
@testable import CompanionPet

struct CodexSessionJSONLParserTests {
    @Test
    func parsesAssistantMessagesAndToolEvents() {
        var parser = CodexSessionJSONLParser()

        let sessionEvents = parser.parse(
            line: #"{"id":"thread-1","timestamp":"2026-05-04T16:00:00Z"}"#,
            source: "codex"
        )
        #expect(sessionEvents.map(\.kind) == [.sessionStarted])

        let toolEvents = parser.parse(
            line: #"{"type":"local_shell_call","id":"tool-1","status":"completed","action":{"type":"exec","command":["bash","-lc","ls -la"]}}"#,
            source: "codex"
        )
        #expect(toolEvents.map(\.kind) == [.toolStarted, .toolFinished])
        #expect(toolEvents.last?.payload["command"] == "bash -lc ls -la")
        #expect(toolEvents.last?.payload["display_command"] == "ls -la")

        let messageEvents = parser.parse(
            line: #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done reviewing the diff."}]}"#,
            source: "codex"
        )
        #expect(messageEvents.map(\.kind) == [.streamStarted, .streamDelta])
        #expect(messageEvents.last?.payload["text"] == "Done reviewing the diff.")
    }

    @Test
    func parsesFailedFunctionOutputAsError() {
        var parser = CodexSessionJSONLParser()
        _ = parser.parse(
            line: #"{"id":"thread-1","timestamp":"2026-05-04T16:00:00Z"}"#,
            source: "codex"
        )

        let events = parser.parse(
            line: #"{"type":"function_call_output","output":"{\"output\":\"permission denied\\n\",\"metadata\":{\"exit_code\":1}}"}"#,
            source: "codex"
        )

        #expect(events.map(\.kind) == [.toolFinished, .error])
        #expect(events.last?.payload["message"] == "permission denied\n")
    }

    @Test
    func parsesCurrentCodexMessageContentShapes() {
        var parser = CodexSessionJSONLParser()

        let userEvents = parser.parse(
            line: #"{"type":"event_msg","payload":{"type":"user_message","message":[{"type":"input_text","text":"Check hatch-pet compatibility"}]}}"#,
            source: "codex"
        )
        #expect(userEvents.map(\.kind) == [.thinkingStarted])
        #expect(userEvents.first?.payload["text"] == "Check hatch-pet compatibility")

        let assistantEvents = parser.parse(
            line: #"{"type":"message","role":"assistant","content":"I found the real Codex breakage."}"#,
            source: "codex"
        )
        #expect(assistantEvents.map(\.kind) == [.streamStarted, .streamDelta])
        #expect(assistantEvents.last?.payload["text"] == "I found the real Codex breakage.")
    }

    @Test
    func sessionMetaCarriesLaunchMetadata() {
        var parser = CodexSessionJSONLParser()

        let events = parser.parse(
            line: #"{"timestamp":"2026-05-06T20:33:34.831Z","type":"session_meta","payload":{"id":"session-ghostty","timestamp":"2026-05-06T20:33:23.787Z","cwd":"/Users/donovan/Documents","originator":"codex-tui","source":"cli"}}"#,
            source: "codex-cli"
        )

        #expect(events.map(\.kind) == [.sessionStarted])
        #expect(events.first?.sessionId == "session-ghostty")
        #expect(events.first?.payload[HostBindingPayloadKey.cwd] == "/Users/donovan/Documents")
        #expect(events.first?.payload[CodexSessionMetadata.PayloadKey.originator] == "codex-tui")
        #expect(events.first?.payload[CodexSessionMetadata.PayloadKey.source] == "cli")
    }
}
