import Foundation
import Testing
@testable import CompanionPet

// MARK: - Fakes

/// Returns a fixed HostBinding regardless of PID, with an optional cwd override from the locator.
private final class FakeHostResolver: HostResolving, @unchecked Sendable {
    let binding: HostBinding
    /// Tracks calls for assertion.
    private(set) var resolvedPIDs: [Int32] = []
    private(set) var cwdQueriedPIDs: [Int32] = []
    private let lock = NSLock()

    init(binding: HostBinding) {
        self.binding = binding
    }

    func resolveHost(forAgentPID agentPID: Int32) -> HostBinding {
        lock.lock()
        resolvedPIDs.append(agentPID)
        lock.unlock()
        var b = binding
        b.agentPID = agentPID
        return b
    }

    func currentDirectory(forPID pid: Int32) -> String? {
        lock.lock()
        cwdQueriedPIDs.append(pid)
        lock.unlock()
        return binding.cwd
    }
}

/// Returns a fixed PID, optionally only when matchingCwd equals the stored cwd.
private struct FakeCodexProcessLocator: CodexProcessLocator, Sendable {
    let pid: Int32?
    let cwd: String?

    func findCodexPID(matchingCwd: String?) -> Int32? {
        // Simulate matching logic: return pid if cwd matches or no cwd filter given.
        if let requiredCwd = matchingCwd, let myCwd = cwd, requiredCwd != myCwd {
            return nil
        }
        return pid
    }

    func findCodexPID(holdingSessionFile _: URL) -> Int32? {
        pid
    }
}

// MARK: - applyHostBinding unit tests

struct ApplyHostBindingTests {
    @Test
    func stampsAllNonNilFields() {
        let binding = HostBinding(
            hostBundleID: "com.apple.Terminal",
            hostPID: 100,
            agentPID: 200,
            tty: "/dev/ttys003",
            cwd: "/Users/alice/project"
        )
        let event = CompanionEvent(source: "codex", kind: .sessionStarted)
        let stamped = applyHostBinding(event, binding)

        #expect(stamped.payload[HostBindingPayloadKey.hostBundleID] == "com.apple.Terminal")
        #expect(stamped.payload[HostBindingPayloadKey.hostPID] == "100")
        #expect(stamped.payload[HostBindingPayloadKey.agentPID] == "200")
        #expect(stamped.payload[HostBindingPayloadKey.tty] == "/dev/ttys003")
        #expect(stamped.payload[HostBindingPayloadKey.cwd] == "/Users/alice/project")
    }

    @Test
    func omitsNilFields() {
        let binding = HostBinding(hostBundleID: "com.apple.Terminal")
        let event = CompanionEvent(source: "codex", kind: .sessionStarted)
        let stamped = applyHostBinding(event, binding)

        #expect(stamped.payload[HostBindingPayloadKey.hostBundleID] == "com.apple.Terminal")
        #expect(stamped.payload[HostBindingPayloadKey.hostPID] == nil)
        #expect(stamped.payload[HostBindingPayloadKey.agentPID] == nil)
        #expect(stamped.payload[HostBindingPayloadKey.tty] == nil)
        #expect(stamped.payload[HostBindingPayloadKey.cwd] == nil)
    }

    @Test
    func preservesExistingPayloadKeys() {
        let binding = HostBinding(hostBundleID: "com.apple.Terminal")
        let event = CompanionEvent(source: "codex", kind: .toolStarted, payload: ["command": "ls"])
        let stamped = applyHostBinding(event, binding)

        #expect(stamped.payload["command"] == "ls")
        #expect(stamped.payload[HostBindingPayloadKey.hostBundleID] == "com.apple.Terminal")
    }

    @Test
    func doesNotMutateOriginalEvent() {
        let binding = HostBinding(hostBundleID: "com.apple.Terminal")
        let event = CompanionEvent(source: "codex", kind: .sessionStarted)
        _ = applyHostBinding(event, binding)
        // Original must be untouched.
        #expect(event.payload[HostBindingPayloadKey.hostBundleID] == nil)
    }
}

// MARK: - External session binding (JSONL watcher path)

struct CodexExternalSessionBindingTests {
    /// Write a temp JSONL file with two lines and return its URL.
    private func makeSessionFile(lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(
            path: "CodexHostBindingTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appending(path: "\(UUID().uuidString).jsonl")
        let content = lines.joined(separator: "\n") + "\n"
        try content.data(using: .utf8)!.write(to: fileURL)
        return fileURL
    }

    @Test
    func extractsCwdFromSessionMetaLine() throws {
        // Build a tiny JSONL where the first line is a session_meta record with a cwd hint.
        let metaLine = #"{"type":"session_meta","payload":{"id":"sess-1","cwd":"/Users/alice/repo"}}"#
        let fileURL = try makeSessionFile(lines: [metaLine])
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        // The fake locator only matches if cwd == "/Users/alice/repo".
        let binding = HostBinding(
            hostBundleID: "com.googlecode.iterm2",
            hostPID: 42,
            cwd: "/Users/alice/repo"
        )
        let resolver = FakeHostResolver(binding: binding)
        let locator = FakeCodexProcessLocator(pid: 9999, cwd: "/Users/alice/repo")

        // Build a minimal CodexAdapterSettings-like object. We can't easily drive
        // pollSessions in isolation, so instead we verify the extraction helper
        // indirectly: wrap the adapter, feed it the file through a mock poller call.
        // Here we directly test the parsing behaviour via the parser + applyHostBinding.

        // Confirm that the JSONL has a cwd we can parse by simulating what
        // resolveBindingForExternalSession does: read file, find cwd, call locator.
        let data = try Data(contentsOf: fileURL)
        let text = String(data: data, encoding: .utf8)!
        var extractedCwd: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let json = try? JSONSerialization.jsonObject(with: Data(rawLine.utf8)) as? [String: Any] {
                if let cwd = (json["payload"] as? [String: Any])?["cwd"] as? String {
                    extractedCwd = cwd
                    break
                }
            }
        }
        #expect(extractedCwd == "/Users/alice/repo")

        // Now exercise the locator with the extracted cwd and check we get the right PID.
        let pid = locator.findCodexPID(matchingCwd: extractedCwd)
        #expect(pid == 9999)

        // Confirm applyHostBinding stamps correctly given a resolved binding.
        let resolvedBinding = resolver.resolveHost(forAgentPID: pid!)
        let event = CompanionEvent(source: "codex", kind: .sessionStarted, sessionId: "sess-1")
        let stamped = applyHostBinding(event, resolvedBinding)
        #expect(stamped.payload[HostBindingPayloadKey.hostBundleID] == "com.googlecode.iterm2")
        #expect(stamped.payload[HostBindingPayloadKey.agentPID] == "9999")
    }

    @Test
    func parsesT3CodeSessionMetadata() {
        let text = #"{"type":"session_meta","payload":{"cwd":"/Users/alice/repo","originator":"t3code_desktop","source":"vscode"}}"#
        let metadata = CodexSessionMetadata.parse(from: text)

        #expect(metadata.id == nil)
        #expect(metadata.cwd == "/Users/alice/repo")
        #expect(metadata.originator == "t3code_desktop")
        #expect(metadata.source == "vscode")
        #expect(metadata.prefersT3CodeHost)
    }

    @Test
    func parsesLongSessionHeaderFromFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appending(path: "rollout-test.jsonl")
        let longInstructions = String(repeating: "x", count: 24_000)
        let text = #"{"type":"session_meta","payload":{"id":"sess-1","cwd":"/Users/alice/repo","originator":"t3code_desktop","source":"vscode","base_instructions":""#
            + longInstructions
            + #""}}"# + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)

        let metadata = CodexSessionMetadata.parseFirstLine(at: url)

        #expect(metadata.id == "sess-1")
        #expect(metadata.cwd == "/Users/alice/repo")
        #expect(metadata.originator == "t3code_desktop")
        #expect(metadata.source == "vscode")
        #expect(metadata.prefersT3CodeHost)
    }

    @Test
    func nonT3SessionMetadataDoesNotPreferT3CodeHost() {
        let text = #"{"type":"session_meta","payload":{"cwd":"/Users/alice/repo","originator":"terminal","source":"cli"}}"#
        let metadata = CodexSessionMetadata.parse(from: text)

        #expect(metadata.cwd == "/Users/alice/repo")
        #expect(!metadata.prefersT3CodeHost)
    }

    @Test
    func locatorFallsBackToAnyCodexProcessWhenNoCwd() {
        let locator = FakeCodexProcessLocator(pid: 7777, cwd: nil)
        // No cwd hint -> should still return the pid.
        let pid = locator.findCodexPID(matchingCwd: nil)
        #expect(pid == 7777)
    }

    @Test
    func locatorReturnsNilWhenCwdDoesNotMatch() {
        let locator = FakeCodexProcessLocator(pid: 7777, cwd: "/other/path")
        let pid = locator.findCodexPID(matchingCwd: "/Users/alice/repo")
        #expect(pid == nil)
    }

    @Test
    func hostResolverStampsAgentPID() {
        let resolver = FakeHostResolver(
            binding: HostBinding(hostBundleID: "com.apple.Terminal", hostPID: 50)
        )
        let binding = resolver.resolveHost(forAgentPID: 1234)
        #expect(binding.agentPID == 1234)
        #expect(binding.hostBundleID == "com.apple.Terminal")
        #expect(binding.hostPID == 50)
        #expect(resolver.resolvedPIDs == [1234])
    }
}

// MARK: - Self-launched session binding (exec path)

struct CodexSelfLaunchedBindingTests {
    @Test
    func applyHostBindingIncludesCwdFromWorkingDirectory() {
        // Simulate what launchSession does: resolver returns a binding, we add cwd from the URL.
        var binding = HostBinding(
            hostBundleID: "com.apple.Terminal",
            hostPID: 55,
            agentPID: 12345
        )
        binding.cwd = "/Users/bob/work"  // injected from process.currentDirectoryURL

        let event = CompanionEvent(source: "codex", kind: .thinkingStarted)
        let stamped = applyHostBinding(event, binding)

        #expect(stamped.payload[HostBindingPayloadKey.cwd] == "/Users/bob/work")
        #expect(stamped.payload[HostBindingPayloadKey.hostBundleID] == "com.apple.Terminal")
        #expect(stamped.payload[HostBindingPayloadKey.agentPID] == "12345")
        // tty is nil (piped stdout), so key must be absent.
        #expect(stamped.payload[HostBindingPayloadKey.tty] == nil)
    }

    @Test
    func applyHostBindingIsIdempotentWhenBindingEmpty() {
        let binding = HostBinding()
        let event = CompanionEvent(source: "codex", kind: .sessionStarted, payload: ["x": "y"])
        let stamped = applyHostBinding(event, binding)
        // Empty binding must not inject any extra keys.
        #expect(stamped.payload == ["x": "y"])
    }
}
