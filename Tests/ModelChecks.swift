import Foundation

@main
struct ModelChecks {
    static func main() throws {
        try quotaWindowsKeepServerValuesAndMissingFields()
        try exhaustedWindowBlocksAvailability()
        try turnErrorDecodesTheCodexErrorCode()
        try turnErrorRecognizesUsageLimitMessage()
        try threadReadinessRecognizesUsageLimitMessage()
        try unrelatedLimitMentionsDoNotResume()
        readinessRequiresConfirmedLimitFailure()
        approvalBlocksResume()
        automaticResumeDefaultsToOptOut()
        print("9 model checks passed")
    }

    private static func quotaWindowsKeepServerValuesAndMissingFields() throws {
        let payload = #"""
        {
          "rateLimits": {
            "limitId": "codex", "limitName": "Codex",
            "primary": {"usedPercent": 73.5, "resetsAt": 1791800000, "windowDurationMins": 300},
            "secondary": {"resetsAt": 1792200000, "windowDurationMins": 10080},
            "credits": {"balance": "12.50", "hasCredits": true, "unlimited": false}, "planType": "plus"
          },
          "rateLimitsByLimitId": {"codex": {
            "limitId": "codex", "limitName": "Codex",
            "primary": {"usedPercent": 73.5, "resetsAt": 1791800000, "windowDurationMins": 300},
            "secondary": {"resetsAt": 1792200000, "windowDurationMins": 10080}
          }},
          "rateLimitResetCredits": {"availableCount": 2}
        }
        """#.data(using: .utf8)!
        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: payload)
        let snapshot = UsageSnapshot(response: response, updatedAt: Date(timeIntervalSince1970: 100))
        try expect(snapshot.windows.count == 2, "both returned quota windows should appear")
        try expect(snapshot.windows[0].window.usedPercent == 73.5, "used percent should remain the server value")
        try expect(snapshot.windows[1].window.usedPercent == nil, "missing usage must remain unavailable")
        try expect(snapshot.allKnownLimitsAvailable == nil, "unknown usage must block auto-resume")
        try expect(snapshot.availableResetCredits == 2, "reset credits should be retained")
    }

    private static func exhaustedWindowBlocksAvailability() throws {
        let payload = #"{"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":300},"secondary":{"usedPercent":14,"windowDurationMins":10080}}}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: payload)
        let snapshot = UsageSnapshot(response: response, updatedAt: Date())
        try expect(snapshot.allKnownLimitsAvailable == false, "an exhausted window should block auto-resume")
    }

    private static func turnErrorDecodesTheCodexErrorCode() throws {
        let payload = #"{"codexErrorInfo":{"type":"UsageLimitExceeded","resetsAt":1791800000},"message":"limit reached"}"#.data(using: .utf8)!
        let value = try JSONDecoder().decode(TurnError.self, from: payload)
        try expect(value.isUsageLimit, "the official usage limit error code should be recognized")
    }

    private static func turnErrorRecognizesUsageLimitMessage() throws {
        let payload = #"{"message":"You’ve hit your usage limit. Upgrade to Pro or try again at 4:15 AM."}"#.data(using: .utf8)!
        let value = try JSONDecoder().decode(TurnError.self, from: payload)
        try expect(value.isUsageLimit, "a real usage-limit message without codexErrorInfo should be recognized")
    }

    private static func threadReadinessRecognizesUsageLimitMessage() throws {
        let payload = #"""
        {
          "thread": {
            "status": {"type": "idle"},
            "turns": [
              {
                "id": "turn-1",
                "status": "failed",
                "error": {"message": "You’ve hit your usage limit. Upgrade to Pro or try again at 4:15 AM."}
              }
            ]
          }
        }
        """#.data(using: .utf8)!
        let detail = try JSONDecoder().decode(ThreadDetailEnvelope.self, from: payload)
        let summary = CodexThreadSummary(id: "thread-1", name: "Fixture project", preview: nil, cwd: nil, path: nil,
                                         source: nil, sourceKind: "cli", createdAt: nil, updatedAt: nil,
                                         ephemeral: false, status: RuntimeThreadStatus(type: "idle", activeFlags: nil))
        let thread = CodexThread.combine(summary, detail: detail)
        try expect(thread.readiness == .rateLimited, "a failed idle thread with a real usage-limit message should be eligible")
    }

    private static func unrelatedLimitMentionsDoNotResume() throws {
        for payload in [
            #"{"codexErrorInfo":"AuthenticationRequired","message":"Check your usage limit in settings"}"#,
            #"{"message":"Remote tool rate limit reached"}"#,
            #"{"message":"Unable to query usage limit"}"#
        ] {
            let error = try JSONDecoder().decode(TurnError.self, from: Data(payload.utf8))
            try expect(!error.isUsageLimit, "unrelated tool/auth failures must not trigger continuation")
        }
    }

    private static func readinessRequiresConfirmedLimitFailure() {
        var thread = makeThread(status: "failed", error: "UsageLimitExceeded")
        expectNoThrow(thread.readiness == .rateLimited, "confirmed rate limit should be eligible")
        thread.lastTurnErrorCode = "AuthenticationRequired"
        expectNoThrow(thread.readiness == .failed, "other failure must not be treated as rate limit")
        thread.runtimeStatus = "active"
        expectNoThrow(thread.readiness == .executing, "active thread must not be resumed")
        thread.runtimeStatus = "notLoaded"
        thread.lastTurnErrorCode = "UsageLimitExceeded"
        expectNoThrow(thread.readiness == .rateLimited, "a not-loaded thread with a terminal limit error remains classifiable")
        thread.runtimeStatus = "unknown"
        thread.lastTurnErrorCode = "UsageLimitExceeded"
        expectNoThrow(thread.readiness == .unknown, "unknown runtime state must block auto-resume")
    }

    private static func approvalBlocksResume() {
        var thread = makeThread(status: "failed", error: "UsageLimitExceeded")
        thread.activeFlags = ["needsApproval"]
        expectNoThrow(thread.readiness == .requiresApproval, "approval state takes precedence")
    }

    private static func automaticResumeDefaultsToOptOut() {
        let preferences = AppPreferences()
        expectNoThrow(!preferences.autoResumeEnabled, "global auto-resume must default off")
        expectNoThrow(!preferences.notificationsEnabled, "notifications must default off")
        expectNoThrow(!preferences.startAtLogin, "login item must default off")
    }

    private static func makeThread(status: String, error: String) -> CodexThread {
        CodexThread(id: "thread-1", title: "Teste", preview: nil, cwd: nil, source: "cli", updatedAt: nil,
                    runtimeStatus: "idle", activeFlags: [], lastTurnID: "turn-1", lastTurnStatus: status,
                    lastTurnErrorCode: error)
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
