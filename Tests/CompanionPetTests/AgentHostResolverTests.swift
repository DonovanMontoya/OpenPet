import Foundation
import Testing
@testable import CompanionPet

// MARK: - Fake providers

private struct FakeProcessTree: ProcessTreeProvider {
    // Maps pid -> ppid. Missing entry means "no parent available".
    let parents: [Int32: Int32]

    func parentPID(of pid: Int32) -> Int32? {
        parents[pid]
    }
}

private struct FakeAppLookup: RunningAppLookup {
    // Set of PIDs that are considered GUI apps.
    let guiPIDs: Set<Int32>
    // Maps pid -> bundleID for GUI apps.
    let bundleIDs: [Int32: String]

    func bundleID(for pid: Int32) -> String? {
        bundleIDs[pid]
    }

    func isGUIApp(pid: Int32) -> Bool {
        guiPIDs.contains(pid)
    }
}

struct AgentHostResolverTests {
    @Test
    func walksUpToFirstGUIAncestor() {
        // Process tree: 1000 (agent) -> 999 -> 998 (GUI)
        let tree = FakeProcessTree(parents: [1000: 999, 999: 998, 998: 1])
        let lookup = FakeAppLookup(
            guiPIDs: [998],
            bundleIDs: [998: "com.example.Terminal"]
        )
        let resolver = AgentHostResolver(processTree: tree, appLookup: lookup)
        let binding = resolver.resolveHost(forAgentPID: 1000)

        #expect(binding.agentPID == 1000)
        #expect(binding.hostPID == 998)
        #expect(binding.hostBundleID == "com.example.Terminal")
    }

    @Test
    func stopsAtPID1() {
        // Tree climbs to launchd (pid 1), no GUI app found.
        let tree = FakeProcessTree(parents: [500: 2, 2: 1])
        let lookup = FakeAppLookup(guiPIDs: [], bundleIDs: [:])
        let resolver = AgentHostResolver(processTree: tree, appLookup: lookup)
        let binding = resolver.resolveHost(forAgentPID: 500)

        #expect(binding.agentPID == 500)
        #expect(binding.hostPID == nil)
        #expect(binding.hostBundleID == nil)
    }

    @Test
    func stopsAtMissingParent() {
        // Agent 600 has no entry in the tree.
        let tree = FakeProcessTree(parents: [:])
        let lookup = FakeAppLookup(guiPIDs: [], bundleIDs: [:])
        let resolver = AgentHostResolver(processTree: tree, appLookup: lookup)
        let binding = resolver.resolveHost(forAgentPID: 600)

        #expect(binding.agentPID == 600)
        #expect(binding.hostPID == nil)
    }

    @Test
    func respectsMaxHops() {
        // Build a chain 100 pids deep; GUI only appears at hop > 16.
        var parents: [Int32: Int32] = [:]
        for i in 1...100 {
            parents[Int32(1000 + i)] = Int32(1000 + i - 1)
        }
        // Make pid 1000 the GUI — it's 100 hops away, beyond the 16-hop limit.
        let tree = FakeProcessTree(parents: parents)
        let lookup = FakeAppLookup(guiPIDs: [1000], bundleIDs: [1000: "com.example.Deep"])
        let resolver = AgentHostResolver(processTree: tree, appLookup: lookup)
        let binding = resolver.resolveHost(forAgentPID: 1100)

        // Should not have found the GUI because max hops was exceeded.
        #expect(binding.hostPID == nil)
        #expect(binding.agentPID == 1100)
    }

    @Test
    func picksClosestGUIAncestor() {
        // Both 97 and 95 are GUI apps; 97 is closer to the agent.
        let tree = FakeProcessTree(parents: [99: 98, 98: 97, 97: 96, 96: 95, 95: 1])
        let lookup = FakeAppLookup(
            guiPIDs: [97, 95],
            bundleIDs: [97: "com.example.Near", 95: "com.example.Far"]
        )
        let resolver = AgentHostResolver(processTree: tree, appLookup: lookup)
        let binding = resolver.resolveHost(forAgentPID: 99)

        #expect(binding.hostPID == 97)
        #expect(binding.hostBundleID == "com.example.Near")
    }
}
