import Foundation

enum CodexConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: "Desconectado"
        case .connecting: "Conectando"
        case .connected: "Conectado ao Codex"
        case .failed(let reason): reason
        }
    }
}

struct UsageWindow: Decodable, Identifiable, Sendable {
    let usedPercent: Double?
    let resetsAt: TimeInterval?
    let windowDurationMins: Int?

    var id: String { "\(windowDurationMins ?? 0)-\(Int(resetsAt ?? 0))" }
    var remainingPercent: Double? { usedPercent.map { max(0, min(100, 100 - $0)) } }
    var isExhausted: Bool { (usedPercent ?? 0) >= 100 }

    func label(kind: String) -> String {
        switch windowDurationMins {
        case 300: "5 horas"
        case 10_080: "Semanal"
        case .some(let minutes): "Janela de \(minutes) min"
        case .none: kind == "primary" ? "Janela principal" : "Janela secundária"
        }
    }
}

struct CreditSnapshot: Decodable, Sendable {
    let balance: String?
    let hasCredits: Bool?
    let unlimited: Bool?
}

struct RateLimitBucket: Decodable, Sendable {
    let limitId: String?
    let limitName: String?
    let primary: UsageWindow?
    let secondary: UsageWindow?
    let credits: CreditSnapshot?
    let planType: String?
    let rateLimitReachedType: String?
    let spendControlReached: Bool?
}

struct RateLimitsResponse: Decodable, Sendable {
    let rateLimits: RateLimitBucket
    let rateLimitsByLimitId: [String: RateLimitBucket]?
    let rateLimitResetCredits: ResetCredits?

    struct ResetCredits: Decodable, Sendable {
        let availableCount: Int?
    }
}

struct QuotaWindow: Identifiable, Sendable {
    let id: String
    let bucketID: String
    let bucketName: String?
    let kind: String
    let window: UsageWindow
    let reachedType: String?

    var title: String {
        let name = bucketName ?? bucketID
        return "\(name) · \(window.label(kind: kind))"
    }

    var isExhausted: Bool {
        window.isExhausted || Self.isReached(reachedType)
    }

    private static func isReached(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return !value.isEmpty && value != "none"
    }
}

struct UsageSnapshot: Sendable {
    let response: RateLimitsResponse
    let updatedAt: Date

    var windows: [QuotaWindow] {
        let fallback = [response.rateLimits.limitId ?? "codex": response.rateLimits]
        let buckets = response.rateLimitsByLimitId.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        return buckets.sorted { ($0.key) < ($1.key) }.flatMap { key, bucket in
            var rows: [QuotaWindow] = []
            if let primary = bucket.primary {
                rows.append(QuotaWindow(id: "\(key):primary", bucketID: bucket.limitId ?? key,
                                        bucketName: bucket.limitName, kind: "primary", window: primary,
                                        reachedType: bucket.rateLimitReachedType))
            }
            if let secondary = bucket.secondary {
                rows.append(QuotaWindow(id: "\(key):secondary", bucketID: bucket.limitId ?? key,
                                        bucketName: bucket.limitName, kind: "secondary", window: secondary,
                                        reachedType: bucket.rateLimitReachedType))
            }
            return rows
        }
    }

    var planType: String? { response.rateLimits.planType }
    var creditBalance: String? { response.rateLimits.credits?.balance }
    var availableResetCredits: Int? { response.rateLimitResetCredits?.availableCount }

    var allKnownLimitsAvailable: Bool? {
        let values = windows
        guard !values.isEmpty else { return nil }
        if values.contains(where: \.isExhausted) { return false }
        guard values.allSatisfy({ $0.window.usedPercent != nil }) else { return nil }
        return true
    }
}

enum ThreadReadiness: String, Codable, Sendable {
    case executing
    case rateLimited
    case awaitingReset
    case availableForResume
    case resuming
    case completed
    case requiresApproval
    case failed
    case unknown
}

struct RuntimeThreadStatus: Decodable, Sendable {
    let type: String
    let activeFlags: [String]?
}

indirect enum JSONValue: Decodable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .null }
    }

    var flattenedText: String {
        switch self {
        case .string(let value): value
        case .number(let value): String(value)
        case .bool(let value): String(value)
        case .object(let values): values.map { "\($0.key) \($0.value.flattenedText)" }.joined(separator: " ")
        case .array(let values): values.map(\.flattenedText).joined(separator: " ")
        case .null: ""
        }
    }
}

struct TurnError: Decodable, Sendable {
    let codexErrorInfo: JSONValue?
    let message: String?

    var normalizedCode: String? {
        if let codexErrorInfo { return codexErrorInfo.flattenedText }
        // Older desktop histories omit the code. Match only the known account-limit message.
        guard Self.isUsageLimitSignal(message) else { return nil }
        return "UsageLimitExceeded"
    }

    var isUsageLimit: Bool {
        Self.isUsageLimitSignal(normalizedCode)
    }

    static func isUsageLimitSignal(_ value: String?) -> Bool {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return normalized.contains("usagelimitexceeded")
            || normalized.hasPrefix("you’ve hit your usage limit.")
            || normalized.hasPrefix("you've hit your usage limit.")
    }

}

struct CodexTurnSummary: Decodable, Sendable {
    let id: String
    let status: String
    let error: TurnError?
}

struct ThreadDetailEnvelope: Decodable, Sendable {
    let thread: ThreadDetail

    struct ThreadDetail: Decodable, Sendable {
        let status: RuntimeThreadStatus?
        let turns: [CodexTurnSummary]?
    }
}

struct ThreadPage: Decodable, Sendable {
    let data: [CodexThreadSummary]
    let nextCursor: String?
}

struct CodexThreadSummary: Decodable, Sendable, Identifiable {
    let id: String
    let name: String?
    let preview: String?
    let cwd: String?
    let path: String?
    let source: String?
    let sourceKind: String?
    let createdAt: TimeInterval?
    let updatedAt: TimeInterval?
    let ephemeral: Bool?
    let status: RuntimeThreadStatus?

    var displayTitle: String {
        let value = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty { return value }
        if let preview, !preview.isEmpty { return String(preview.prefix(72)) }
        return "Conversa sem título"
    }

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Projeto não identificado" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}

struct CodexThread: Identifiable, Codable, Sendable {
    let id: String
    let title: String
    let preview: String?
    let cwd: String?
    let source: String?
    let updatedAt: Date?
    var runtimeStatus: String
    var activeFlags: [String]
    var lastTurnID: String?
    var lastTurnStatus: String?
    var lastTurnErrorCode: String?

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Projeto não identificado" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    var readiness: ThreadReadiness {
        let normalizedStatus = runtimeStatus.lowercased()
        if normalizedStatus.contains("approval") || normalizedStatus.contains("userinput") {
            return .requiresApproval
        }
        if activeFlags.contains(where: { $0.localizedCaseInsensitiveContains("approval") || $0.localizedCaseInsensitiveContains("userInput") }) {
            return .requiresApproval
        }
        if normalizedStatus == "active" { return .executing }
        if ["inProgress", "queued", "pending"].contains(lastTurnStatus ?? "") { return .executing }
        if !activeFlags.isEmpty || !["idle", "notloaded"].contains(normalizedStatus) { return .unknown }
        if lastTurnStatus == "failed", TurnError.isUsageLimitSignal(lastTurnErrorCode) {
            return .rateLimited
        }
        if lastTurnStatus == "completed" { return .completed }
        if lastTurnStatus == "failed" { return .failed }
        return .unknown
    }

    static func combine(_ summary: CodexThreadSummary, detail: ThreadDetailEnvelope?) -> CodexThread {
        let latest = detail?.thread.turns?.last
        return CodexThread(id: summary.id, title: summary.displayTitle, preview: summary.preview,
                           cwd: summary.cwd ?? summary.path, source: summary.sourceKind ?? summary.source,
                           updatedAt: summary.updatedAt.map(Date.init(timeIntervalSince1970:)),
                           runtimeStatus: detail?.thread.status?.type ?? summary.status?.type ?? "unknown",
                           activeFlags: detail?.thread.status?.activeFlags ?? summary.status?.activeFlags ?? [],
                           lastTurnID: latest?.id, lastTurnStatus: latest?.status,
                           lastTurnErrorCode: latest?.error?.normalizedCode)
    }
}

struct UsageSample: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let windows: [WindowSample]

    struct WindowSample: Codable, Identifiable, Sendable {
        let id: String
        let label: String
        let usedPercent: Double?
    }

    init(snapshot: UsageSnapshot) {
        id = UUID()
        timestamp = snapshot.updatedAt
        windows = snapshot.windows.map {
            WindowSample(id: $0.id, label: $0.title, usedPercent: $0.window.usedPercent)
        }
    }
}

enum ResumeAttemptStatus: String, Codable, Sendable {
    case prepared
    case accepted
    case completed
    case failed
    case unknown
}

struct ResumeAttempt: Codable, Identifiable, Sendable {
    var id: String { "\(threadID):\(failedTurnID)" }
    let threadID: String
    let failedTurnID: String
    var attempt: Int
    var status: ResumeAttemptStatus
    var createdAt: Date
    var updatedAt: Date
    var startedTurnID: String?
    var message: String?
}

enum ResumeRetryDecision: Equatable, Sendable {
    case start
    case wait(until: Date)
    case skip
}

enum ResumeRetryPolicy {
    private static let maxBackoff: TimeInterval = 60 * 60

    static func decision(for previousAttempt: ResumeAttempt?, now: Date) -> ResumeRetryDecision {
        guard let previousAttempt else { return .start }
        guard previousAttempt.startedTurnID == nil else { return .skip }
        switch previousAttempt.status {
        case .prepared:
            return retryAfterBackoff(previousAttempt, now: now)
        case .accepted, .completed:
            return .skip
        case .unknown:
            return retryAfterBackoff(previousAttempt, now: now)
        case .failed:
            if previousAttempt.message?.hasPrefix("Retomada adiada:") == true {
                let retryAt = previousAttempt.updatedAt.addingTimeInterval(60)
                return now >= retryAt ? .start : .wait(until: retryAt)
            }
            guard isTransientActiveWriterMessage(previousAttempt.message) else { return .skip }
            return retryAfterBackoff(previousAttempt, now: now)
        }
    }

    static func isTransientActiveWriterMessage(_ message: String?) -> Bool {
        guard let message else { return false }
        let normalized = message.lowercased()
        return normalized.contains("already has an active writer")
            || normalized.contains("already has a live local writer")
    }

    private static func retryAfterBackoff(_ attempt: ResumeAttempt, now: Date) -> ResumeRetryDecision {
        let exponent = max(0, min(attempt.attempt - 1, 6))
        let delay = min(maxBackoff, TimeInterval(60 * (1 << exponent)))
        let retryAt = attempt.updatedAt.addingTimeInterval(delay)
        return now >= retryAt ? .start : .wait(until: retryAt)
    }
}

struct AppPreferences: Codable, Equatable, Sendable {
    var codexExecutablePath = ""
    var codexHome = ""
    var monitoringEnabled = true
    var refreshIntervalSeconds = 60
    var autoResumeEnabled = false
    var continuationMessage = "Continue a tarefa anterior a partir do ponto em que foi interrompida. Preserve o contexto, respeite as instruções existentes e não repita ações já concluídas. Caso a tarefa já esteja finalizada ou dependa de uma decisão humana, não inicie trabalho adicional."
    var notificationsEnabled = false
    var historyRetentionDays = 90
    var startAtLogin = false
}
