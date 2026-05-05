import Foundation

enum CompanionStateName: String, Codable, CaseIterable, Sendable {
    case idle
    case ambient
    case thinking
    case working
    case replying
    case success
    case error
    case waitingForUser = "waiting_for_user"
    case disconnected
    case sleeping
    case jumping
    case waving
}

enum CompanionEventKind: String, Codable, CaseIterable, Sendable {
    case sessionStarted = "session_started"
    case sessionEnded = "session_ended"
    case thinkingStarted = "thinking_started"
    case thinkingStopped = "thinking_stopped"
    case toolStarted = "tool_started"
    case toolFinished = "tool_finished"
    case streamStarted = "stream_started"
    case streamDelta = "stream_delta"
    case streamFinished = "stream_finished"
    case error
    case userWaiting = "user_waiting"
    case adapterConnected = "adapter_connected"
    case adapterDisconnected = "adapter_disconnected"
    case systemIdle = "system_idle"
    case gitChanged = "git_changed"
    case buildStarted = "build_started"
    case buildSucceeded = "build_succeeded"
    case buildFailed = "build_failed"
    case codingStarted = "coding_started"
    case codingStopped = "coding_stopped"
    case focusStarted = "focus_started"
    case focusBreak = "focus_break"
}

struct CompanionEvent: Codable, Equatable, Sendable {
    var source: String
    var kind: CompanionEventKind
    var timestamp: Date
    var sessionId: String?
    var modelId: String?
    var payload: [String: String]

    init(
        source: String,
        kind: CompanionEventKind,
        timestamp: Date = .now,
        sessionId: String? = nil,
        modelId: String? = nil,
        payload: [String: String] = [:]
    ) {
        self.source = source
        self.kind = kind
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.modelId = modelId
        self.payload = payload
    }
}

enum AdapterHealthState: String, Codable, Sendable {
    case connected
    case degraded
    case disconnected
}

struct AdapterHealth: Equatable, Sendable {
    var state: AdapterHealthState
    var lastErrorText: String?

    static let connected = AdapterHealth(state: .connected, lastErrorText: nil)
    static let disconnected = AdapterHealth(state: .disconnected, lastErrorText: nil)
}

enum AdapterCapability: String, CaseIterable, Hashable, Sendable {
    case launchesSessions
    case proxiesRequests
    case healthChecks
}

protocol CompanionAdapter: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: Set<AdapterCapability> { get }
    func health() async -> AdapterHealth
    func events() -> AsyncStream<CompanionEvent>
    func start() async
    func stop() async
}

final class EventChannel<Value: Sendable>: @unchecked Sendable {
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    private let lock = NSLock()

    func stream() -> AsyncStream<Value> {
        let token = UUID()
        return AsyncStream { continuation in
            self.withLock {
                self.continuations[token] = continuation
            }
            continuation.onTermination = { _ in
                self.withLock {
                    _ = self.continuations.removeValue(forKey: token)
                }
            }
        }
    }

    func send(_ value: Value) {
        let activeContinuations = withLock {
            Array(continuations.values)
        }
        for continuation in activeContinuations {
            continuation.yield(value)
        }
    }

    func finish() {
        let active = withLock { () -> [AsyncStream<Value>.Continuation] in
            let active = Array(continuations.values)
            continuations.removeAll()
            return active
        }
        for continuation in active {
            continuation.finish()
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
