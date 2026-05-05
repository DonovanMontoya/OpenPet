import Foundation
import Testing
@testable import CompanionPet

struct OpenCodeExportParserTests {
    @Test
    func parsesUserPromptAndFinalReply() {
        var parser = OpenCodeExportParser()
        let export = #"""
Exporting session: ses_test
{
  "messages": [
    {
      "info": {
        "role": "user",
        "id": "msg_user",
        "sessionID": "ses_test",
        "time": { "created": 1000 }
      },
      "parts": [
        { "type": "text", "text": "hello", "id": "prt_user_1" }
      ]
    },
    {
      "info": {
        "role": "assistant",
        "id": "msg_assistant",
        "sessionID": "ses_test",
        "finish": "stop",
        "time": { "created": 1100 }
      },
      "parts": [
        { "type": "step-start", "id": "prt_assistant_start" },
        { "type": "reasoning", "text": "thinking about it", "time": { "start": 1200, "end": 1300 }, "id": "prt_assistant_reasoning" },
        { "type": "text", "text": "Hello! How can I help you today?", "time": { "start": 1400, "end": 1500 }, "id": "prt_assistant_text" },
        { "type": "step-finish", "reason": "stop", "time": { "start": 1500, "end": 1600 }, "id": "prt_assistant_finish" }
      ]
    }
  ]
}
"""#

        let events = parser.parse(exportText: export, source: "opencode-cli")
        let kinds: [CompanionEventKind] = events.map(\.kind)
        #expect(kinds == [.sessionStarted, .thinkingStarted, .thinkingStarted, .streamStarted, .streamDelta, .streamFinished, .sessionEnded])
        #expect(events.first(where: { $0.kind == .streamDelta })?.payload["text"] == "Hello! How can I help you today?")
    }

    @Test
    func parsesCompletedToolCallsAndAvoidsDuplicatesAcrossPolls() {
        var parser = OpenCodeExportParser()
        let export = #"""
{
  "messages": [
    {
      "info": {
        "role": "user",
        "id": "msg_user",
        "sessionID": "ses_test",
        "time": { "created": 1000 }
      },
      "parts": [
        { "type": "text", "text": "check files", "id": "prt_user_1" }
      ]
    },
    {
      "info": {
        "role": "assistant",
        "id": "msg_assistant",
        "sessionID": "ses_test",
        "finish": "tool-calls",
        "time": { "created": 1100 }
      },
      "parts": [
        { "type": "step-start", "id": "prt_assistant_start" },
        {
          "type": "tool",
          "tool": "glob",
          "id": "prt_tool_1",
          "state": {
            "status": "completed",
            "input": { "pattern": "**/*.swift" },
            "output": "Sources/Foo.swift",
            "time": { "start": 1200, "end": 1300 }
          }
        },
        { "type": "step-finish", "reason": "tool-calls", "time": { "start": 1300, "end": 1400 }, "id": "prt_assistant_finish" }
      ]
    }
  ]
}
"""#

        let firstEvents = parser.parse(exportText: export, source: "opencode-cli")
        let firstKinds: [CompanionEventKind] = firstEvents.map(\.kind)
        #expect(firstKinds.contains(.toolStarted))
        #expect(firstKinds.contains(.toolFinished))

        let secondEvents = parser.parse(exportText: export, source: "opencode-cli")
        #expect(secondEvents.isEmpty)
    }

    @Test
    func sanitizesVisibleThoughtChannelLeak() {
        var parser = OpenCodeExportParser()
        let export = #"""
{
  "messages": [
    {
      "info": {
        "role": "user",
        "id": "msg_user",
        "sessionID": "ses_test",
        "time": { "created": 1000 }
      },
      "parts": [
        { "type": "text", "text": "hi", "id": "prt_user_1" }
      ]
    },
    {
      "info": {
        "role": "assistant",
        "id": "msg_assistant",
        "sessionID": "ses_test",
        "finish": "stop",
        "time": { "created": 1100 }
      },
      "parts": [
        { "type": "text", "text": "<|channel><|channel>\tthought\nHello! How can I help you today?", "time": { "start": 1200, "end": 1300 }, "id": "prt_text_1" },
        { "type": "step-finish", "reason": "stop", "time": { "start": 1300, "end": 1400 }, "id": "prt_finish_1" }
      ]
    }
  ]
}
"""#

        let events = parser.parse(exportText: export, source: "opencode-cli")
        #expect(events.first(where: { $0.kind == .streamDelta })?.payload["text"] == "Hello! How can I help you today?")
    }
}
