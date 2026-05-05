import Foundation

struct BehaviorSnapshot: Equatable, Sendable {
    var currentState: CompanionStateName
    var nextWakeAt: Date?
}

final class CompanionBehaviorEngine {
    typealias AmbientDelayProvider = () -> TimeInterval
    private static let sleepAfterSeconds: TimeInterval = 240

    private let ambientDelayProvider: AmbientDelayProvider

    private(set) var currentState: CompanionStateName = .idle
    private var lastEventAt: Date?
    private var lastInteractionAt: Date?
    private var nextAmbientAt: Date?
    private var transientUntil: Date?
    private var activeToolCount = 0
    private var isThinking = false
    private var isStreaming = false
    private var waitingForUser = false
    private var connectedSources: Set<String> = []

    init(ambientDelayProvider: @escaping AmbientDelayProvider = { Double.random(in: 90...180) }) {
        self.ambientDelayProvider = ambientDelayProvider
    }

    func handle(event: CompanionEvent, at: Date? = nil) -> BehaviorSnapshot {
        let now = at ?? event.timestamp
        lastEventAt = now

        switch event.kind {
        case .adapterConnected:
            connectedSources.insert(event.source)
        case .adapterDisconnected:
            connectedSources.remove(event.source)
        case .gitChanged:
            connectedSources.insert(event.source)
            waitingForUser = false
            scheduleTransient(.ambient, until: now.addingTimeInterval(2.2))
            scheduleAmbient(from: now)
        case .buildStarted:
            connectedSources.insert(event.source)
            waitingForUser = false
            activeToolCount += 1
            isThinking = false
            clearTransient()
            currentState = .working
        case .buildSucceeded:
            connectedSources.insert(event.source)
            waitingForUser = false
            activeToolCount = 0
            isThinking = false
            isStreaming = false
            scheduleTransient(.success, until: now.addingTimeInterval(1.5))
            scheduleAmbient(from: now)
        case .buildFailed:
            connectedSources.insert(event.source)
            waitingForUser = false
            activeToolCount = 0
            isThinking = false
            isStreaming = false
            scheduleTransient(.error, until: now.addingTimeInterval(2))
            scheduleAmbient(from: now)
        case .codingStarted:
            connectedSources.insert(event.source)
            waitingForUser = false
            activeToolCount += 1
            isThinking = false
            clearTransient()
            currentState = .working
        case .codingStopped:
            connectedSources.insert(event.source)
            activeToolCount = max(0, activeToolCount - 1)
            scheduleAmbient(from: now)
        case .focusStarted:
            connectedSources.insert(event.source)
            waitingForUser = false
            activeToolCount = 0
            isThinking = true
            isStreaming = false
            clearTransient()
            currentState = .thinking
            scheduleAmbient(from: now)
        case .focusBreak:
            connectedSources.insert(event.source)
            waitingForUser = false
            activeToolCount = 0
            isThinking = false
            isStreaming = false
            scheduleTransient(.success, until: now.addingTimeInterval(1.5))
            scheduleAmbient(from: now)
        case .sessionStarted, .thinkingStarted:
            waitingForUser = false
            isThinking = true
            isStreaming = false
            clearTransient()
            scheduleAmbient(from: now)
        case .thinkingStopped:
            isThinking = false
        case .toolStarted:
            waitingForUser = false
            activeToolCount += 1
            isThinking = false
            clearTransient()
        case .toolFinished:
            activeToolCount = max(0, activeToolCount - 1)
        case .streamStarted:
            waitingForUser = false
            isThinking = false
            isStreaming = true
            clearTransient()
        case .streamDelta:
            waitingForUser = false
            isThinking = false
            isStreaming = true
        case .streamFinished:
            isStreaming = false
        case .error:
            waitingForUser = false
            activeToolCount = 0
            isThinking = false
            isStreaming = false
            scheduleTransient(.error, until: now.addingTimeInterval(2))
            scheduleAmbient(from: now)
        case .sessionEnded:
            activeToolCount = 0
            isThinking = false
            isStreaming = false
            waitingForUser = false
            scheduleTransient(.success, until: now.addingTimeInterval(1.5))
            scheduleAmbient(from: now)
        case .userWaiting:
            waitingForUser = true
        case .systemIdle:
            break
        }

        return advance(to: now)
    }

    func recordInteraction(at now: Date = .now) -> BehaviorSnapshot {
        lastInteractionAt = now
        if currentState == .sleeping {
            currentState = .idle
        }
        scheduleAmbient(from: now)
        return advance(to: now)
    }

    func recordJump(at now: Date = .now) -> BehaviorSnapshot {
        lastInteractionAt = now
        // Matches the Codex atlas "jumping" row total (~1050ms) so the baked sprite plays through.
        scheduleTransient(.jumping, until: now.addingTimeInterval(1.1))
        scheduleAmbient(from: now)
        return advance(to: now)
    }

    func recordWave(at now: Date = .now) -> BehaviorSnapshot {
        lastInteractionAt = now
        // ~1.5s lets the Codex "waving" row loop ~1.7x for a friendly greeting beat.
        scheduleTransient(.waving, until: now.addingTimeInterval(1.5))
        scheduleAmbient(from: now)
        return advance(to: now)
    }

    func advance(to now: Date = .now) -> BehaviorSnapshot {
        if let transientUntil, now >= transientUntil {
            clearTransient()
            currentState = derivedState(at: now)
        }

        if currentState != .success
            && currentState != .error
            && currentState != .ambient
            && currentState != .jumping
            && currentState != .waving {
            currentState = derivedState(at: now)
        }

        if currentState == .idle, let nextAmbientAt, now >= nextAmbientAt {
            scheduleTransient(.ambient, until: now.addingTimeInterval(2.2))
            currentState = .ambient
            self.nextAmbientAt = nil
        }

        if currentState == .idle && nextAmbientAt == nil {
            scheduleAmbient(from: activityReferenceDate(defaulting: now))
        }

        return BehaviorSnapshot(
            currentState: currentState,
            nextWakeAt: nextWakeDate(from: now)
        )
    }

    private func derivedState(at now: Date) -> CompanionStateName {
        guard !connectedSources.isEmpty else {
            return .disconnected
        }

        if isStreaming {
            return .replying
        }

        if activeToolCount > 0 {
            return .working
        }

        if isThinking {
            return .thinking
        }

        if waitingForUser {
            return .waitingForUser
        }

        if let referenceDate = activityReferenceDate(), now.timeIntervalSince(referenceDate) >= Self.sleepAfterSeconds {
            return .sleeping
        }

        return .idle
    }

    private func nextWakeDate(from now: Date) -> Date? {
        var candidates: [Date] = []

        if let transientUntil {
            candidates.append(transientUntil)
        }
        if let nextAmbientAt {
            candidates.append(nextAmbientAt)
        }
        if let referenceDate = activityReferenceDate() {
            let sleepDeadline = referenceDate.addingTimeInterval(Self.sleepAfterSeconds)
            if sleepDeadline > now {
                candidates.append(sleepDeadline)
            }
        }

        return candidates.min()
    }

    private func activityReferenceDate(defaulting defaultDate: Date? = nil) -> Date {
        activityReferenceDate() ?? defaultDate ?? .now
    }

    private func activityReferenceDate() -> Date? {
        [lastEventAt, lastInteractionAt].compactMap { $0 }.max()
    }

    private func scheduleAmbient(from now: Date) {
        nextAmbientAt = now.addingTimeInterval(ambientDelayProvider())
    }

    private func scheduleTransient(_ state: CompanionStateName, until: Date) {
        currentState = state
        transientUntil = until
    }

    private func clearTransient() {
        transientUntil = nil
    }
}
