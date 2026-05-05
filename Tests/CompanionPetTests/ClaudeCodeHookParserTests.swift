import Foundation
import Testing
@testable import CompanionPet

struct ClaudeCodeHookParserTests {
    private let parser = ClaudeCodeHookParser()

    @Test
    func parsesPreToolUse() {
        let events = parser.parse(
            payload: [
                "hook_event_name": "PreToolUse",
                "session_id": "session-1",
                "tool_name": "Bash",
                "tool_input": ["command": "swift test"],
            ],
            source: "claude-code"
        )

        #expect(events.map(\.kind) == [.thinkingStarted, .toolStarted])
        #expect(events.first?.payload["text"] == "swift test")
        #expect(events.last?.payload["command"] == "swift test")
    }

    @Test
    func parsesPostToolUseSuccessAndError() {
        let success = parser.parse(
            payload: [
                "hook_event_name": "PostToolUse",
                "session_id": "session-1",
                "tool_name": "Bash",
                "tool_input": ["command": "swift test"],
            ],
            source: "claude-code"
        )
        #expect(success.map(\.kind) == [.toolFinished])

        let failure = parser.parse(
            payload: [
                "hook_event_name": "PostToolUse",
                "session_id": "session-1",
                "tool_name": "Bash",
                "tool_input": ["command": "swift test"],
                "tool_response": ["error": "command failed"],
            ],
            source: "claude-code"
        )
        #expect(failure.map(\.kind) == [.toolFinished, .error])
        #expect(failure.last?.payload["message"] == "command failed")
    }

    @Test
    func parsesStopNotificationAndSubagentStop() {
        let stop = parser.parse(payload: ["hook_event_name": "Stop", "session_id": "session-1"], source: "claude-code")
        #expect(stop.map(\.kind) == [.streamFinished, .sessionEnded])

        let waiting = parser.parse(
            payload: [
                "hook_event_name": "Notification",
                "session_id": "session-1",
                "notification_type": "waiting_for_input",
            ],
            source: "claude-code"
        )
        #expect(waiting.map(\.kind) == [.userWaiting])

        let ignoredNotification = parser.parse(
            payload: [
                "hook_event_name": "Notification",
                "session_id": "session-1",
                "notification_type": "idle_prompt",
            ],
            source: "claude-code"
        )
        #expect(ignoredNotification.isEmpty)

        let subagentStop = parser.parse(payload: ["hook_event_name": "SubagentStop", "session_id": "session-1"], source: "claude-code")
        #expect(subagentStop.map(\.kind) == [.sessionEnded])
    }
}
