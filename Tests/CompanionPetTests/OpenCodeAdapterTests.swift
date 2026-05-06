import Foundation
import Testing
@testable import CompanionPet

// MARK: - Fakes

private struct FakeHostResolver: HostResolving {
    let binding: HostBinding

    func resolveHost(forAgentPID agentPID: Int32) -> HostBinding {
        var b = binding
        b.agentPID = agentPID
        return b
    }

    func currentDirectory(forPID pid: Int32) -> String? {
        binding.cwd
    }
}

private struct FakeProcessLocator: OpenCodeProcessLocator {
    let pids: [Int32]

    func agentPIDs() -> [Int32] {
        pids
    }
}

// MARK: - Tests

struct OpenCodeAdapterTests {
    // MARK: applyHostBinding

    @Test
    func applyHostBindingStampsAllFields() {
        let adapter = OpenCodeAdapter(
            settings: OpenCodeAdapterSettings.fixture(),
            agentHostResolver: FakeHostResolver(
                binding: HostBinding(
                    hostBundleID: "com.example.App",
                    hostPID: 100,
                    agentPID: 200,
                    tty: "/dev/ttys001",
                    cwd: "/Users/test/project"
                )
            ),
            processLocator: FakeProcessLocator(pids: [200])
        )

        let event = CompanionEvent(source: "opencode-cli", kind: .thinkingStarted, sessionId: "ses_abc")
        let binding = HostBinding(
            hostBundleID: "com.example.App",
            hostPID: 100,
            agentPID: 200,
            tty: "/dev/ttys001",
            cwd: "/Users/test/project"
        )
        let stamped = adapter.applyHostBinding(event, binding)

        #expect(stamped.payload[HostBindingPayloadKey.hostBundleID] == "com.example.App")
        #expect(stamped.payload[HostBindingPayloadKey.hostPID] == "100")
        #expect(stamped.payload[HostBindingPayloadKey.agentPID] == "200")
        #expect(stamped.payload[HostBindingPayloadKey.tty] == "/dev/ttys001")
        #expect(stamped.payload[HostBindingPayloadKey.cwd] == "/Users/test/project")
    }

    @Test
    func applyHostBindingEmptyBindingReturnsUnchangedEvent() {
        let adapter = OpenCodeAdapter(
            settings: OpenCodeAdapterSettings.fixture(),
            agentHostResolver: FakeHostResolver(binding: HostBinding()),
            processLocator: FakeProcessLocator(pids: [])
        )

        let event = CompanionEvent(
            source: "opencode-cli",
            kind: .thinkingStarted,
            sessionId: "ses_abc",
            payload: ["text": "hello"]
        )
        let result = adapter.applyHostBinding(event, HostBinding())

        #expect(result.payload == event.payload)
        #expect(result.kind == event.kind)
    }

    @Test
    func applyHostBindingPartialBindingOnlyStampsPresentFields() {
        let adapter = OpenCodeAdapter(
            settings: OpenCodeAdapterSettings.fixture(),
            agentHostResolver: FakeHostResolver(binding: HostBinding()),
            processLocator: FakeProcessLocator(pids: [])
        )

        let event = CompanionEvent(source: "opencode-cli", kind: .toolStarted, sessionId: "ses_xyz")
        let binding = HostBinding(hostBundleID: "com.apple.Terminal", agentPID: 42)
        let stamped = adapter.applyHostBinding(event, binding)

        #expect(stamped.payload[HostBindingPayloadKey.hostBundleID] == "com.apple.Terminal")
        #expect(stamped.payload[HostBindingPayloadKey.agentPID] == "42")
        #expect(stamped.payload[HostBindingPayloadKey.hostPID] == nil)
        #expect(stamped.payload[HostBindingPayloadKey.tty] == nil)
        #expect(stamped.payload[HostBindingPayloadKey.cwd] == nil)
    }

    @Test
    func applyHostBindingPreservesExistingPayloadFields() {
        let adapter = OpenCodeAdapter(
            settings: OpenCodeAdapterSettings.fixture(),
            agentHostResolver: FakeHostResolver(binding: HostBinding()),
            processLocator: FakeProcessLocator(pids: [])
        )

        let event = CompanionEvent(
            source: "opencode-cli",
            kind: .streamDelta,
            sessionId: "ses_abc",
            payload: ["text": "some response text"]
        )
        let binding = HostBinding(hostBundleID: "com.googlecode.iterm2", hostPID: 77)
        let stamped = adapter.applyHostBinding(event, binding)

        #expect(stamped.payload["text"] == "some response text")
        #expect(stamped.payload[HostBindingPayloadKey.hostBundleID] == "com.googlecode.iterm2")
    }
}

// MARK: - Test fixture

private extension OpenCodeAdapterSettings {
    static func fixture() -> OpenCodeAdapterSettings {
        OpenCodeAdapterSettings()
    }
}
