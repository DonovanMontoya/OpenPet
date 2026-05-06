import Foundation

struct HostBinding: Equatable, Codable, Sendable {
    var hostBundleID: String?
    var hostPID: Int32?
    var agentPID: Int32?
    var tty: String?
    var cwd: String?

    var isEmpty: Bool { hostBundleID == nil && hostPID == nil && agentPID == nil && tty == nil && cwd == nil }
}

enum HostBindingPayloadKey {
    static let hostBundleID = "host_bundle_id"
    static let hostPID = "host_pid"
    static let agentPID = "agent_pid"
    static let tty = "tty"
    static let cwd = "cwd"
}

extension HostBinding {
    static func fromPayload(_ payload: [String: String]) -> HostBinding? {
        let binding = HostBinding(
            hostBundleID: payload[HostBindingPayloadKey.hostBundleID].flatMap { $0.isEmpty ? nil : $0 },
            hostPID: payload[HostBindingPayloadKey.hostPID].flatMap { Int32($0) },
            agentPID: payload[HostBindingPayloadKey.agentPID].flatMap { Int32($0) },
            tty: payload[HostBindingPayloadKey.tty].flatMap { $0.isEmpty ? nil : $0 },
            cwd: payload[HostBindingPayloadKey.cwd].flatMap { $0.isEmpty ? nil : $0 }
        )
        return binding.isEmpty ? nil : binding
    }

    func merging(_ other: HostBinding?) -> HostBinding {
        guard let other else { return self }
        return HostBinding(
            hostBundleID: other.hostBundleID ?? hostBundleID,
            hostPID: other.hostPID ?? hostPID,
            agentPID: other.agentPID ?? agentPID,
            tty: other.tty ?? tty,
            cwd: other.cwd ?? cwd
        )
    }
}
