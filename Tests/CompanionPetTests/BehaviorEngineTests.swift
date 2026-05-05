import Foundation
import Testing
@testable import CompanionPet

struct BehaviorEngineTests {
    @Test
    func transitionsThroughThinkingWorkingReplyingAndWaiting() {
        let baseDate = Date(timeIntervalSince1970: 1_000)
        let engine = CompanionBehaviorEngine(ambientDelayProvider: { 60 })

        let connected = engine.handle(
            event: CompanionEvent(source: "test", kind: .adapterConnected, timestamp: baseDate)
        )
        #expect(connected.currentState == .idle)

        let thinking = engine.handle(
            event: CompanionEvent(source: "test", kind: .sessionStarted, timestamp: baseDate.addingTimeInterval(1))
        )
        #expect(thinking.currentState == .thinking)

        let working = engine.handle(
            event: CompanionEvent(source: "test", kind: .toolStarted, timestamp: baseDate.addingTimeInterval(2))
        )
        #expect(working.currentState == .working)

        let replying = engine.handle(
            event: CompanionEvent(source: "test", kind: .streamStarted, timestamp: baseDate.addingTimeInterval(3))
        )
        #expect(replying.currentState == .replying)

        let success = engine.handle(
            event: CompanionEvent(source: "test", kind: .sessionEnded, timestamp: baseDate.addingTimeInterval(4))
        )
        #expect(success.currentState == .success)

        let idle = engine.advance(to: baseDate.addingTimeInterval(5.6))
        #expect(idle.currentState == .idle)

        let waiting = engine.handle(
            event: CompanionEvent(source: "test", kind: .userWaiting, timestamp: baseDate.addingTimeInterval(6))
        )
        #expect(waiting.currentState == .waitingForUser)

        let stillWaiting = engine.advance(to: baseDate.addingTimeInterval(90))
        #expect(stillWaiting.currentState == .waitingForUser)

        let nextTurn = engine.handle(
            event: CompanionEvent(source: "test", kind: .thinkingStarted, timestamp: baseDate.addingTimeInterval(91))
        )
        #expect(nextTurn.currentState == .thinking)
    }

    @Test
    func disconnectWinsOverIdleAndErrorReturnsToIdle() {
        let baseDate = Date(timeIntervalSince1970: 2_000)
        let engine = CompanionBehaviorEngine(ambientDelayProvider: { 45 })

        _ = engine.handle(event: CompanionEvent(source: "test", kind: .adapterConnected, timestamp: baseDate))
        let error = engine.handle(
            event: CompanionEvent(source: "test", kind: .error, timestamp: baseDate.addingTimeInterval(1))
        )
        #expect(error.currentState == .error)

        let recovered = engine.advance(to: baseDate.addingTimeInterval(3.2))
        #expect(recovered.currentState == .idle)

        let disconnected = engine.handle(
            event: CompanionEvent(source: "test", kind: .adapterDisconnected, timestamp: baseDate.addingTimeInterval(4))
        )
        #expect(disconnected.currentState == .disconnected)
    }

    @Test
    func localActivityEventsReuseExistingAnimationStates() {
        let baseDate = Date(timeIntervalSince1970: 3_000)
        let engine = CompanionBehaviorEngine(ambientDelayProvider: { 60 })

        let gitMood = engine.handle(
            event: CompanionEvent(source: "manual", kind: .gitChanged, timestamp: baseDate)
        )
        #expect(gitMood.currentState == .ambient)

        let buildStarted = engine.handle(
            event: CompanionEvent(source: "manual", kind: .buildStarted, timestamp: baseDate.addingTimeInterval(3))
        )
        #expect(buildStarted.currentState == .working)

        let buildSucceeded = engine.handle(
            event: CompanionEvent(source: "manual", kind: .buildSucceeded, timestamp: baseDate.addingTimeInterval(4))
        )
        #expect(buildSucceeded.currentState == .success)

        let codingStarted = engine.handle(
            event: CompanionEvent(source: "manual", kind: .codingStarted, timestamp: baseDate.addingTimeInterval(6))
        )
        #expect(codingStarted.currentState == .working)

        let codingStopped = engine.handle(
            event: CompanionEvent(source: "manual", kind: .codingStopped, timestamp: baseDate.addingTimeInterval(7))
        )
        #expect(codingStopped.currentState == .idle)

        let focusStarted = engine.handle(
            event: CompanionEvent(source: "manual", kind: .focusStarted, timestamp: baseDate.addingTimeInterval(8))
        )
        #expect(focusStarted.currentState == .thinking)

        let focusBreak = engine.handle(
            event: CompanionEvent(source: "manual", kind: .focusBreak, timestamp: baseDate.addingTimeInterval(9))
        )
        #expect(focusBreak.currentState == .success)
    }

    @Test
    func recordJumpProducesTransientJumpingStateAndReturnsToIdle() {
        let baseDate = Date(timeIntervalSince1970: 4_000)
        let engine = CompanionBehaviorEngine(ambientDelayProvider: { 60 })

        _ = engine.handle(event: CompanionEvent(source: "test", kind: .adapterConnected, timestamp: baseDate))

        let jumping = engine.recordJump(at: baseDate.addingTimeInterval(1))
        #expect(jumping.currentState == .jumping)

        let stillJumping = engine.advance(to: baseDate.addingTimeInterval(1.5))
        #expect(stillJumping.currentState == .jumping)

        let landed = engine.advance(to: baseDate.addingTimeInterval(2.5))
        #expect(landed.currentState == .idle)
    }

    @Test
    func recordJumpReturnsToActiveWorkState() {
        let baseDate = Date(timeIntervalSince1970: 4_500)
        let engine = CompanionBehaviorEngine(ambientDelayProvider: { 60 })

        _ = engine.handle(event: CompanionEvent(source: "test", kind: .adapterConnected, timestamp: baseDate))
        _ = engine.handle(event: CompanionEvent(source: "test", kind: .toolStarted, timestamp: baseDate.addingTimeInterval(1)))

        let jumping = engine.recordJump(at: baseDate.addingTimeInterval(2))
        #expect(jumping.currentState == .jumping)

        let resumed = engine.advance(to: baseDate.addingTimeInterval(3.2))
        #expect(resumed.currentState == .working)
    }

    @Test
    func recordWaveProducesTransientWavingStateAndReturnsToIdle() {
        let baseDate = Date(timeIntervalSince1970: 5_000)
        let engine = CompanionBehaviorEngine(ambientDelayProvider: { 60 })

        _ = engine.handle(event: CompanionEvent(source: "test", kind: .adapterConnected, timestamp: baseDate))

        let waving = engine.recordWave(at: baseDate.addingTimeInterval(1))
        #expect(waving.currentState == .waving)

        let midWave = engine.advance(to: baseDate.addingTimeInterval(2.0))
        #expect(midWave.currentState == .waving)

        let done = engine.advance(to: baseDate.addingTimeInterval(3.0))
        #expect(done.currentState == .idle)
    }

    @Test
    func recordWaveReturnsToWaitingState() {
        let baseDate = Date(timeIntervalSince1970: 5_500)
        let engine = CompanionBehaviorEngine(ambientDelayProvider: { 60 })

        _ = engine.handle(event: CompanionEvent(source: "test", kind: .adapterConnected, timestamp: baseDate))
        _ = engine.handle(event: CompanionEvent(source: "test", kind: .userWaiting, timestamp: baseDate.addingTimeInterval(1)))

        let waving = engine.recordWave(at: baseDate.addingTimeInterval(2))
        #expect(waving.currentState == .waving)

        let resumed = engine.advance(to: baseDate.addingTimeInterval(3.6))
        #expect(resumed.currentState == .waitingForUser)
    }

    @Test
    func recordJumpResetsAmbientTimer() {
        let baseDate = Date(timeIntervalSince1970: 6_000)
        let engine = CompanionBehaviorEngine(ambientDelayProvider: { 30 })

        _ = engine.handle(event: CompanionEvent(source: "test", kind: .adapterConnected, timestamp: baseDate))
        let jumping = engine.recordJump(at: baseDate.addingTimeInterval(1))
        #expect(jumping.currentState == .jumping)

        // The wake target should be at most the configured ambient delay from the jump time.
        let wake = try? #require(jumping.nextWakeAt)
        if let wake {
            let delta = wake.timeIntervalSince(baseDate.addingTimeInterval(1))
            #expect(delta <= 30 + 0.001)
        }
    }

    @Test
    func sleepsAfterFourMinutesOfInactivity() {
        let baseDate = Date(timeIntervalSince1970: 7_000)
        let engine = CompanionBehaviorEngine(ambientDelayProvider: { 600 })

        _ = engine.handle(event: CompanionEvent(source: "test", kind: .adapterConnected, timestamp: baseDate))

        let awake = engine.advance(to: baseDate.addingTimeInterval(239))
        #expect(awake.currentState == .idle)

        let sleeping = engine.advance(to: baseDate.addingTimeInterval(240))
        #expect(sleeping.currentState == .sleeping)

        let woke = engine.recordInteraction(at: baseDate.addingTimeInterval(241))
        #expect(woke.currentState == .idle)
    }

    @Test
    func waitingForUserAlsoSleepsAfterFourMinutesOfInactivity() {
        let baseDate = Date(timeIntervalSince1970: 8_000)
        let engine = CompanionBehaviorEngine(ambientDelayProvider: { 600 })

        _ = engine.handle(event: CompanionEvent(source: "test", kind: .adapterConnected, timestamp: baseDate))
        let waiting = engine.handle(
            event: CompanionEvent(source: "test", kind: .userWaiting, timestamp: baseDate.addingTimeInterval(1))
        )
        #expect(waiting.currentState == .waitingForUser)

        let stillWaiting = engine.advance(to: baseDate.addingTimeInterval(240))
        #expect(stillWaiting.currentState == .waitingForUser)

        let sleeping = engine.advance(to: baseDate.addingTimeInterval(241))
        #expect(sleeping.currentState == .sleeping)
    }
}
