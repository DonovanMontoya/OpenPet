import Foundation
import Testing
@testable import CompanionPet

struct HostBindingTests {
    @Test
    func fromPayloadEmptyDictionaryReturnsNil() {
        #expect(HostBinding.fromPayload([:]) == nil)
    }

    @Test
    func fromPayloadBlankStringsReturnNil() {
        let payload: [String: String] = [
            HostBindingPayloadKey.hostBundleID: "",
            HostBindingPayloadKey.tty: "",
            HostBindingPayloadKey.cwd: "",
        ]
        #expect(HostBinding.fromPayload(payload) == nil)
    }

    @Test
    func fromPayloadPartialFillsOnlyPresentKeys() throws {
        let payload: [String: String] = [
            HostBindingPayloadKey.hostBundleID: "com.apple.Terminal",
            HostBindingPayloadKey.agentPID: "1234",
        ]
        let binding = try #require(HostBinding.fromPayload(payload))
        #expect(binding.hostBundleID == "com.apple.Terminal")
        #expect(binding.agentPID == 1234)
        #expect(binding.hostPID == nil)
        #expect(binding.tty == nil)
        #expect(binding.cwd == nil)
    }

    @Test
    func fromPayloadFullPopulatesAllFields() throws {
        let payload: [String: String] = [
            HostBindingPayloadKey.hostBundleID: "com.googlecode.iterm2",
            HostBindingPayloadKey.hostPID: "500",
            HostBindingPayloadKey.agentPID: "501",
            HostBindingPayloadKey.tty: "/dev/ttys003",
            HostBindingPayloadKey.cwd: "/Users/alice/project",
        ]
        let binding = try #require(HostBinding.fromPayload(payload))
        #expect(binding.hostBundleID == "com.googlecode.iterm2")
        #expect(binding.hostPID == 500)
        #expect(binding.agentPID == 501)
        #expect(binding.tty == "/dev/ttys003")
        #expect(binding.cwd == "/Users/alice/project")
    }

    @Test
    func fromPayloadInvalidPIDIsNil() throws {
        let payload: [String: String] = [
            HostBindingPayloadKey.hostBundleID: "com.apple.Terminal",
            HostBindingPayloadKey.hostPID: "not-a-number",
        ]
        let binding = try #require(HostBinding.fromPayload(payload))
        #expect(binding.hostPID == nil)
    }

    @Test
    func mergingNilReturnsSelf() {
        let base = HostBinding(hostBundleID: "com.apple.Terminal", tty: "/dev/ttys001")
        let merged = base.merging(nil)
        #expect(merged == base)
    }

    @Test
    func mergingNonNilFieldsWin() {
        let base = HostBinding(hostBundleID: "com.apple.Terminal", hostPID: 100, tty: "/dev/ttys001")
        let other = HostBinding(hostBundleID: "com.googlecode.iterm2", agentPID: 200)
        let merged = base.merging(other)
        // other's non-nil fields win
        #expect(merged.hostBundleID == "com.googlecode.iterm2")
        #expect(merged.agentPID == 200)
        // base fields preserved when other has nil
        #expect(merged.hostPID == 100)
        #expect(merged.tty == "/dev/ttys001")
    }

    @Test
    func mergingPreservesBaseWhenOtherEmpty() {
        let base = HostBinding(hostBundleID: "com.apple.Terminal", hostPID: 42)
        let other = HostBinding()
        let merged = base.merging(other)
        #expect(merged.hostBundleID == "com.apple.Terminal")
        #expect(merged.hostPID == 42)
    }

    @Test
    func isEmptyOnlyWhenAllNil() {
        #expect(HostBinding().isEmpty)
        #expect(!HostBinding(hostBundleID: "x").isEmpty)
        #expect(!HostBinding(hostPID: 1).isEmpty)
        #expect(!HostBinding(agentPID: 1).isEmpty)
        #expect(!HostBinding(tty: "/dev/ttys000").isEmpty)
        #expect(!HostBinding(cwd: "/tmp").isEmpty)
    }
}
