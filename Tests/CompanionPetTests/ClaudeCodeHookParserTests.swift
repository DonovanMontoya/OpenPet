import Foundation
import Testing
@testable import CompanionPet

// MARK: - Fakes

private struct FakeSessionLookup: ClaudeSessionLookup {
    let result: (pid: Int32, cwd: String)?

    func info(forSessionID sessionID: String) -> (pid: Int32, cwd: String)? {
        result
    }
}

private struct FakeProcessTree: ProcessTreeProvider {
    let parents: [Int32: Int32]
    func parentPID(of pid: Int32) -> Int32? { parents[pid] }
}

private struct FakeAppLookup: RunningAppLookup {
    let guiPIDs: Set<Int32>
    let bundleIDs: [Int32: String]
    func bundleID(for pid: Int32) -> String? { bundleIDs[pid] }
    func isGUIApp(pid: Int32) -> Bool { guiPIDs.contains(pid) }
}

private func makeResolver(hostPID: Int32, hostBundleID: String, agentPID: Int32) -> AgentHostResolver {
    let tree = FakeProcessTree(parents: [agentPID: hostPID, hostPID: 1])
    let lookup = FakeAppLookup(guiPIDs: [hostPID], bundleIDs: [hostPID: hostBundleID])
    return AgentHostResolver(processTree: tree, appLookup: lookup)
}

// MARK: - Tests

struct ClaudeCodeHookParserTests {
    private let noopSessionLookup = FakeSessionLookup(result: nil)
    private let noopResolver = AgentHostResolver(
        processTree: FakeProcessTree(parents: [:]),
        appLookup: FakeAppLookup(guiPIDs: [], bundleIDs: [:])
    )

    private func makeParser(
        sessionLookup: ClaudeSessionLookup? = nil,
        resolver: AgentHostResolver? = nil
    ) -> ClaudeCodeHookParser {
        ClaudeCodeHookParser(
            sessionLookup: sessionLookup ?? noopSessionLookup,
            hostResolver: resolver ?? noopResolver
        )
    }

    // MARK: - Existing behaviour

    @Test
    func parsesPreToolUse() {
        let events = makeParser().parse(
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
        let success = makeParser().parse(
            payload: [
                "hook_event_name": "PostToolUse",
                "session_id": "session-1",
                "tool_name": "Bash",
                "tool_input": ["command": "swift test"],
            ],
            source: "claude-code"
        )
        #expect(success.map(\.kind) == [.toolFinished])

        let failure = makeParser().parse(
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
        let stop = makeParser().parse(payload: ["hook_event_name": "Stop", "session_id": "session-1"], source: "claude-code")
        #expect(stop.map(\.kind) == [.streamFinished, .sessionEnded])

        let waiting = makeParser().parse(
            payload: [
                "hook_event_name": "Notification",
                "session_id": "session-1",
                "notification_type": "waiting_for_input",
            ],
            source: "claude-code"
        )
        #expect(waiting.map(\.kind) == [.userWaiting])

        let ignoredNotification = makeParser().parse(
            payload: [
                "hook_event_name": "Notification",
                "session_id": "session-1",
                "notification_type": "idle_prompt",
            ],
            source: "claude-code"
        )
        #expect(ignoredNotification.isEmpty)

        let subagentStop = makeParser().parse(payload: ["hook_event_name": "SubagentStop", "session_id": "session-1"], source: "claude-code")
        #expect(subagentStop.map(\.kind) == [.sessionEnded])
    }

    // MARK: - Host binding: env keys

    @Test
    func hostBundleIDAndTTYPopulatedFromEnvKeys() {
        let events = makeParser().parse(
            payload: [
                "hook_event_name": "Stop",
                "session_id": "s1",
                "openpet_host_bundle_id": "com.apple.Terminal",
                "openpet_tty": "/dev/ttys001",
                "openpet_host_ppid": "5000",
                "openpet_term_program": "Apple_Terminal",
            ],
            source: "claude-code"
        )
        // Both events from Stop carry host payload
        for event in events {
            #expect(event.payload[HostBindingPayloadKey.tty] == "/dev/ttys001")
            // No session lookup match and resolver has no GUI app, so env bundle id is the fallback
            #expect(event.payload[HostBindingPayloadKey.hostBundleID] == "com.apple.Terminal")
        }
    }

    @Test
    func emptyEnvKeysAreDropped() {
        let events = makeParser().parse(
            payload: [
                "hook_event_name": "Stop",
                "session_id": "s1",
                "openpet_host_bundle_id": "",
                "openpet_tty": "",
            ],
            source: "claude-code"
        )
        for event in events {
            #expect(event.payload[HostBindingPayloadKey.tty] == nil)
            #expect(event.payload[HostBindingPayloadKey.hostBundleID] == nil)
        }
    }

    // MARK: - Host binding: session lookup

    @Test
    func sessionLookupPopulatesAgentPIDAndCWD() {
        let lookup = FakeSessionLookup(result: (pid: 12345, cwd: "/tmp/x"))
        let events = makeParser(sessionLookup: lookup).parse(
            payload: ["hook_event_name": "Stop", "session_id": "session-abc"],
            source: "claude-code"
        )
        for event in events {
            #expect(event.payload[HostBindingPayloadKey.agentPID] == "12345")
            #expect(event.payload[HostBindingPayloadKey.cwd] == "/tmp/x")
        }
    }

    @Test
    func noSessionMatchLeavesAgentPIDAndCWDAbsent() {
        let events = makeParser(sessionLookup: FakeSessionLookup(result: nil)).parse(
            payload: ["hook_event_name": "Stop", "session_id": "session-xyz"],
            source: "claude-code"
        )
        for event in events {
            #expect(event.payload[HostBindingPayloadKey.agentPID] == nil)
            #expect(event.payload[HostBindingPayloadKey.cwd] == nil)
        }
    }

    // MARK: - Host binding: resolver

    @Test
    func resolverResultWinsOverEnvVarBundleID() {
        // Resolver wins when both resolver and env var produce a bundle id — the resolver
        // inspects the live ppid tree rather than trusting an env var that may be inherited
        // from an unrelated ancestor process.
        let lookup = FakeSessionLookup(result: (pid: 9000, cwd: "/workspace"))
        let resolver = makeResolver(hostPID: 42, hostBundleID: "com.apple.Terminal", agentPID: 9000)

        let events = makeParser(sessionLookup: lookup, resolver: resolver).parse(
            payload: [
                "hook_event_name": "Stop",
                "session_id": "s",
                "openpet_host_bundle_id": "com.stale.EnvVar",
            ],
            source: "claude-code"
        )
        for event in events {
            #expect(event.payload[HostBindingPayloadKey.hostPID] == "42")
            #expect(event.payload[HostBindingPayloadKey.hostBundleID] == "com.apple.Terminal")
        }
    }

    @Test
    func resolverBundleIDFallsBackToEnvVarWhenResolverFindsNone() {
        // Resolver found no GUI ancestor; env-var bundle id is used as a best-effort fallback.
        let lookup = FakeSessionLookup(result: (pid: 8000, cwd: "/home"))
        // Resolver has no GUI apps, so it returns no hostBundleID.
        let emptyResolver = AgentHostResolver(
            processTree: FakeProcessTree(parents: [8000: 1]),
            appLookup: FakeAppLookup(guiPIDs: [], bundleIDs: [:])
        )

        let events = makeParser(sessionLookup: lookup, resolver: emptyResolver).parse(
            payload: [
                "hook_event_name": "Stop",
                "session_id": "s",
                "openpet_host_bundle_id": "com.apple.Terminal",
                "openpet_host_ppid": "7777",
            ],
            source: "claude-code"
        )
        for event in events {
            #expect(event.payload[HostBindingPayloadKey.hostBundleID] == "com.apple.Terminal")
            // Resolver set agentPID=8000 but found no hostPID, so env-var PPID is the fallback
            #expect(event.payload[HostBindingPayloadKey.hostPID] == "7777")
        }
    }

    @Test
    func hostPayloadPropagatedToAllEventTypesFromPreToolUse() {
        // Verify that every event produced by PreToolUse carries the host binding payload.
        let lookup = FakeSessionLookup(result: (pid: 5555, cwd: "/code"))
        let resolver = makeResolver(hostPID: 100, hostBundleID: "com.example.IDE", agentPID: 5555)

        let events = makeParser(sessionLookup: lookup, resolver: resolver).parse(
            payload: [
                "hook_event_name": "PreToolUse",
                "session_id": "s2",
                "tool_name": "Bash",
                "tool_input": ["command": "make"],
                "openpet_tty": "/dev/ttys002",
            ],
            source: "claude-code"
        )
        #expect(events.map(\.kind) == [.thinkingStarted, .toolStarted])
        for event in events {
            #expect(event.payload[HostBindingPayloadKey.agentPID] == "5555")
            #expect(event.payload[HostBindingPayloadKey.cwd] == "/code")
            #expect(event.payload[HostBindingPayloadKey.hostPID] == "100")
            #expect(event.payload[HostBindingPayloadKey.hostBundleID] == "com.example.IDE")
            #expect(event.payload[HostBindingPayloadKey.tty] == "/dev/ttys002")
        }
    }
}
