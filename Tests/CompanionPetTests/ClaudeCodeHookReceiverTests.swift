import Foundation
import Testing
@testable import CompanionPet

struct ClaudeCodeHookReceiverTests {
    @Test
    func mergesHooksIdempotentlyAndRemovesOnlyOpenPetHooks() throws {
        let rootDirectory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "OpenPet-ClaudeHookReceiver-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let settingsURL = rootDirectory.appending(path: "settings.json")
        let initialSettings = """
        {
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [
                  {
                    "type": "command",
                    "command": "/usr/bin/true"
                  }
                ]
              }
            ]
          }
        }
        """
        try Data(initialSettings.utf8).write(to: settingsURL)

        let receiver = ClaudeCodeHookReceiver(
            port: Int.random(in: 29100...29200),
            source: "claude-code",
            channel: EventChannel<CompanionEvent>(),
            settingsURL: settingsURL
        )

        try receiver.start()
        defer { receiver.stop() }

        let mergedData = try Data(contentsOf: settingsURL)
        let mergedJSON = try #require(JSONSerialization.jsonObject(with: mergedData) as? [String: Any])
        let mergedHooks = try #require(mergedJSON["hooks"] as? [String: Any])
        let preToolGroups = try #require(mergedHooks["PreToolUse"] as? [[String: Any]])
        #expect(preToolGroups.count == 2)

        receiver.stop()

        let finalData = try Data(contentsOf: settingsURL)
        let finalJSON = try #require(JSONSerialization.jsonObject(with: finalData) as? [String: Any])
        let finalHooks = try #require(finalJSON["hooks"] as? [String: Any])
        let finalPreToolGroups = try #require(finalHooks["PreToolUse"] as? [[String: Any]])
        #expect(finalPreToolGroups.count == 1)
        let remainingHooks = try #require(finalPreToolGroups.first?["hooks"] as? [[String: Any]])
        #expect(remainingHooks.first?["command"] as? String == "/usr/bin/true")
        #expect(finalHooks["Stop"] == nil)
    }
}
