import Foundation

@main
struct RetryChecks {
    static func main() throws {
        try unknownAttemptsRetryAfterBackoffWithoutPermanentCap()
        try activeWriterFailuresRetryAfterBackoff()
        acceptedCompletedAndStartedUnknownDoNotDuplicate()
        nonTransientFailuresStayStopped()
        try preparedAttemptsWaitBeforeReconciliation()
        try definiteDeferralsRetryPromptly()
        print("6 retry checks passed")
    }

    private static func unknownAttemptsRetryAfterBackoffWithoutPermanentCap() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let recent = makeAttempt(attempt: 3, status: .unknown, updatedAt: now.addingTimeInterval(-100))
        try expect(ResumeRetryPolicy.decision(for: recent, now: now) == .wait(until: recent.updatedAt.addingTimeInterval(240)),
                   "attempt 3 should wait for exponential backoff, not retry immediately")

        let old = makeAttempt(attempt: 9, status: .unknown, updatedAt: now.addingTimeInterval(-3_601))
        try expect(ResumeRetryPolicy.decision(for: old, now: now) == .start,
                   "unknown attempts past the old hard cap should retry once backoff has elapsed")
    }

    private static func activeWriterFailuresRetryAfterBackoff() throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let attempt = makeAttempt(attempt: 3, status: .failed, updatedAt: now.addingTimeInterval(-300),
                                  message: "thread fixture already has an active writer")
        try expect(ResumeRetryPolicy.decision(for: attempt, now: now) == .start,
                   "active-writer failures should be treated as transient after backoff")
    }

    private static func acceptedCompletedAndStartedUnknownDoNotDuplicate() {
        let now = Date(timeIntervalSince1970: 30_000)
        expectNoThrow(ResumeRetryPolicy.decision(for: makeAttempt(status: .accepted), now: now) == .skip,
                      "accepted attempts should prevent duplicate starts")
        expectNoThrow(ResumeRetryPolicy.decision(for: makeAttempt(status: .completed), now: now) == .skip,
                      "completed attempts should prevent duplicate starts")
        expectNoThrow(ResumeRetryPolicy.decision(for: makeAttempt(status: .unknown, startedTurnID: "turn-2"), now: now) == .skip,
                      "unknown attempts with a started turn should not duplicate a possibly running turn")
        expectNoThrow(ResumeRetryPolicy.decision(for: makeAttempt(status: .failed, startedTurnID: "turn-2", message: "Retomada adiada: gravação local"), now: now) == .skip,
                      "a known dispatched turn must prevent retries regardless of journal status")
    }

    private static func nonTransientFailuresStayStopped() {
        let now = Date(timeIntervalSince1970: 40_000)
        let attempt = makeAttempt(status: .failed, message: "authentication required")
        expectNoThrow(ResumeRetryPolicy.decision(for: attempt, now: now) == .skip,
                      "ordinary request failures should remain stopped")
    }

    private static func preparedAttemptsWaitBeforeReconciliation() throws {
        let now = Date(timeIntervalSince1970: 50_000)
        let attempt = makeAttempt(status: .prepared, updatedAt: now)
        try expect(ResumeRetryPolicy.decision(for: attempt, now: now) == .wait(until: now.addingTimeInterval(60)),
                   "crash recovery must wait for a potentially dispatched turn to become visible")
        let started = makeAttempt(status: .prepared, startedTurnID: "turn-2")
        try expect(ResumeRetryPolicy.decision(for: started, now: now) == .skip,
                   "a prepared record with a known new turn must not duplicate it")
    }

    private static func definiteDeferralsRetryPromptly() throws {
        let now = Date(timeIntervalSince1970: 60_000)
        let attempt = makeAttempt(attempt: 9, status: .failed, updatedAt: now.addingTimeInterval(-61),
                                  message: "Retomada adiada: conversa não carregada")
        try expect(ResumeRetryPolicy.decision(for: attempt, now: now) == .start,
                   "a definitively undispatched desktop request should retry on the next monitor interval")
    }

    private static func makeAttempt(attempt: Int = 1,
                                    status: ResumeAttemptStatus,
                                    updatedAt: Date = Date(timeIntervalSince1970: 1),
                                    startedTurnID: String? = nil,
                                    message: String? = nil) -> ResumeAttempt {
        ResumeAttempt(threadID: "thread-1", failedTurnID: "failed-turn-1", attempt: attempt,
                      status: status, createdAt: Date(timeIntervalSince1970: 0), updatedAt: updatedAt,
                      startedTurnID: startedTurnID, message: message)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure(message: message) }
    }

    private static func expectNoThrow(_ condition: Bool, _ message: String) {
        if !condition { fatalError("Check failed: \(message)") }
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { "Check failed: \(message)" }
}
