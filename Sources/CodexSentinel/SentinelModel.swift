import Foundation
import ServiceManagement
import UserNotifications
import Combine
import Darwin

@MainActor
final class SentinelModel: ObservableObject {
    @Published private(set) var connection: CodexConnectionStatus = .disconnected
    @Published private(set) var usage: UsageSnapshot?
    @Published private(set) var threads: [CodexThread] = []
    @Published private(set) var usageHistory: [UsageSample] = []
    @Published private(set) var attempts: [ResumeAttempt] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var refreshProgress: String?
    @Published var preferences: AppPreferences { didSet { persistPreferences() } }

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let supportDirectory: URL
    private var client: AppServerClient?
    private var clientKey: String?
    private var monitorTask: Task<Void, Never>?
    private var inFlightResumes = Set<String>()
    private var refreshInProgress = false

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        supportDirectory = base.appendingPathComponent("Codex Sentinel", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
        if let data = defaults.data(forKey: "preferences"), let saved = try? decoder.decode(AppPreferences.self, from: data) {
            preferences = saved
        } else {
            preferences = AppPreferences()
        }
        usageHistory = load([UsageSample].self, from: "usage-history.json") ?? []
        attempts = load([ResumeAttempt].self, from: "resume-attempts.json") ?? []
        applyRetention()
    }

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.preferences.monitoringEnabled { await self.refresh() }
                let delay = max(15, self.preferences.refreshIntervalSeconds)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        let previousClient = client
        client = nil
        clientKey = nil
        connection = .disconnected
        Task { await previousClient?.stop() }
    }

    func refresh() async {
        guard preferences.monitoringEnabled, !refreshInProgress else { return }
        refreshInProgress = true
        defer { refreshInProgress = false }
        connection = .connecting
        refreshProgress = "Consultando cotas"
        do {
            let activeClient = try await configuredClient()
            let freshUsage = try await activeClient.readRateLimits()
            usage = freshUsage
            lastError = nil
            appendSample(UsageSample(snapshot: freshUsage))

            refreshProgress = "Listando conversas"
            var allSummaries: [CodexThreadSummary] = []
            var cursor: String?
            var seenCursors = Set<String>()
            while true {
                let page = try await activeClient.listThreads(cursor: cursor)
                allSummaries.append(contentsOf: page.data)
                guard let nextCursor = page.nextCursor, seenCursors.insert(nextCursor).inserted else { break }
                cursor = nextCursor
            }

            let cutoff = Date().addingTimeInterval(-Double(preferences.historyRetentionDays) * 86_400)
            let recent = allSummaries.filter { summary in
                guard summary.ephemeral != true else { return false }
                guard let timestamp = summary.updatedAt else { return true }
                return Date(timeIntervalSince1970: timestamp) >= cutoff
            }
            let resumeAcrossAllChats = preferences.autoResumeEnabled && usage?.allKnownLimitsAvailable == true
            let retryIDs = Set(attempts.filter { ResumeRetryPolicy.decision(for: $0, now: Date()) == .start }.map(\.threadID))
            let summariesToRead = (resumeAcrossAllChats
                ? allSummaries.filter { $0.ephemeral != true }
                : recent).sorted { retryIDs.contains($0.id) && !retryIDs.contains($1.id) }
            let recentIDs = Set(recent.map(\.id))
            refreshProgress = "Lendo 0 de \(summariesToRead.count) conversas"
            var refreshed: [CodexThread] = []
            var completedReads = 0
            for batchStart in stride(from: 0, to: summariesToRead.count, by: 6) {
                let batchEnd = min(batchStart + 6, summariesToRead.count)
                let batch = Array(summariesToRead[batchStart..<batchEnd])
                let batchResults = await withTaskGroup(of: (Int, CodexThread).self) { group in
                    for (index, summary) in batch.enumerated() {
                        group.addTask {
                            let detail: ThreadDetailEnvelope?
                            do { detail = try await activeClient.readThread(id: summary.id) }
                            catch { detail = nil }
                            return (index, CodexThread.combine(summary, detail: detail))
                        }
                    }
                    var results: [(Int, CodexThread)] = []
                    for await result in group { results.append(result) }
                    return results.sorted { $0.0 < $1.0 }
                }
                for (_, thread) in batchResults {
                    reconcileStartedAttempt(with: thread)
                    if recentIDs.contains(thread.id) { refreshed.append(thread) }
                }
                threads = refreshed.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                if resumeAcrossAllChats {
                    await considerAutomaticResumes(using: activeClient, in: batchResults.map { $0.1 })
                }
                completedReads += batch.count
                refreshProgress = "Lendo \(completedReads) de \(summariesToRead.count) conversas"
            }
            threads = refreshed.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            lastRefresh = Date()
            connection = .connected
            refreshProgress = nil
            if !resumeAcrossAllChats { await considerAutomaticResumes(using: activeClient, in: refreshed) }
        } catch {
            let message = error.localizedDescription
            lastError = message
            connection = .failed(message)
            refreshProgress = nil
            let failedClient = client
            client = nil
            clientKey = nil
            Task { await failedClient?.stop() }
        }
    }

    func setAutoResumeEnabled(_ enabled: Bool) {
        preferences.autoResumeEnabled = enabled
        if enabled { Task { await refresh() } }
    }

    func setMonitoringEnabled(_ enabled: Bool) {
        preferences.monitoringEnabled = enabled
        if enabled { startMonitoring() }
        else { stopMonitoring() }
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        if enabled {
            let center = UNUserNotificationCenter.current()
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                preferences.notificationsEnabled = granted
                if !granted { lastError = "Notificações não foram autorizadas no macOS." }
            } catch { lastError = error.localizedDescription }
        } else {
            preferences.notificationsEnabled = false
        }
    }

    func setStartAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            preferences.startAtLogin = enabled
        } catch {
            lastError = "Não foi possível atualizar a abertura no início da sessão: \(error.localizedDescription)"
            preferences.startAtLogin = false
        }
    }

    private func configuredClient() async throws -> AppServerClient {
        let executable = try resolveCodexExecutable()
        let home = preferences.codexHome.isEmpty ? nil : preferences.codexHome
        let key = "\(executable.path)|\(home ?? "")"
        if let client, clientKey == key { return client }
        if let client { await client.stop() }
        let newClient = AppServerClient(executableURL: executable, codexHome: home)
        try await newClient.start()
        client = newClient
        clientKey = key
        return newClient
    }

    private func resolveCodexExecutable() throws -> URL {
        if !preferences.codexExecutablePath.isEmpty {
            let candidate = URL(fileURLWithPath: preferences.codexExecutablePath).standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { throw AppServerError.executableNotFound }
            return candidate
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw AppServerError.executableNotFound
    }

    private func considerAutomaticResumes(using client: AppServerClient, in candidates: [CodexThread]) async {
        guard preferences.autoResumeEnabled,
              usage?.allKnownLimitsAvailable == true else { return }
        let now = Date()
        for thread in candidates where thread.readiness == .rateLimited {
            guard let failedTurnID = thread.lastTurnID else { continue }
            let key = "\(thread.id):\(failedTurnID)"
            guard !inFlightResumes.contains(key) else { continue }
            let previousAttempt = attempts.first(where: { $0.id == key })
            switch ResumeRetryPolicy.decision(for: previousAttempt, now: now) {
            case .start:
                await performResume(thread: thread, failedTurnID: failedTurnID, key: key, client: client)
            case .wait(let retryAt):
                let retryTime = retryAt.formatted(date: .omitted, time: .shortened)
                if let message = previousAttempt?.message, !message.isEmpty {
                    lastError = "A retomada de \(thread.title) será tentada novamente às \(retryTime). Último erro: \(message)"
                } else {
                    lastError = "A retomada de \(thread.title) será tentada novamente às \(retryTime)."
                }
            case .skip:
                continue
            }
        }
    }

    private func performResume(thread: CodexThread, failedTurnID: String, key: String, client: AppServerClient) async {
        inFlightResumes.insert(key)
        defer { inFlightResumes.remove(key) }
        guard preferences.monitoringEnabled, preferences.autoResumeEnabled,
              usage?.allKnownLimitsAvailable == true else { return }
        do {
            let freshUsage = try await client.readRateLimits()
            usage = freshUsage
            guard freshUsage.allKnownLimitsAvailable == true else { return }
            let detail = try await client.readThread(id: thread.id)
            let latest = detail.thread.turns?.last
            let runtimeStatus = detail.thread.status?.type ?? thread.runtimeStatus
            let activeFlags = detail.thread.status?.activeFlags ?? thread.activeFlags
            let freshThread = CodexThread(id: thread.id, title: thread.title, preview: thread.preview,
                                          cwd: thread.cwd, source: thread.source, updatedAt: thread.updatedAt,
                                          runtimeStatus: runtimeStatus, activeFlags: activeFlags,
                                          lastTurnID: latest?.id, lastTurnStatus: latest?.status,
                                          lastTurnErrorCode: latest?.error?.normalizedCode)
            guard freshThread.lastTurnID == failedTurnID,
                  freshThread.readiness == .rateLimited else { return }
        } catch {
            lastError = "Não foi possível revalidar a conversa antes da retomada: \(error.localizedDescription)"
            return
        }
        guard preferences.monitoringEnabled, preferences.autoResumeEnabled,
              usage?.allKnownLimitsAvailable == true else { return }
        let count = (attempts.first { $0.id == key }?.attempt ?? 0) + 1
        do {
            try upsertAttempt(ResumeAttempt(threadID: thread.id, failedTurnID: failedTurnID, attempt: count,
                                            status: .prepared, createdAt: Date(), updatedAt: Date(),
                                            startedTurnID: nil, message: nil))
        } catch {
            lastError = "O diário local não pôde ser gravado; nenhuma retomada foi iniciada. \(error.localizedDescription)"
            return
        }
        var startedTurnID: String?
        do {
            let turnID = try await client.resume(threadID: thread.id, prompt: preferences.continuationMessage)
            startedTurnID = turnID
            try upsertAttempt(ResumeAttempt(threadID: thread.id, failedTurnID: failedTurnID, attempt: count,
                                            status: .accepted, createdAt: Date(), updatedAt: Date(),
                                            startedTurnID: turnID, message: nil))
            sendNotification(title: "Retomada iniciada", body: thread.title)
            Task { [weak self] in
                do {
                    let completion = try await client.waitForTurnCompletion(id: turnID)
                    await MainActor.run { self?.recordCompletion(key: key, status: completion.status) }
                } catch {
                    await MainActor.run { self?.recordCompletion(key: key, status: "unknown") }
                }
            }
        } catch {
            let errorMessage = error.localizedDescription
            let attemptStatus: ResumeAttemptStatus
            if case AppServerError.resumeDeferred = error {
                attemptStatus = .failed
            } else if case AppServerError.requestFailed = error {
                attemptStatus = .failed
            } else {
                // The request may have reached Codex before the channel failed; reconcile before any retry.
                attemptStatus = .unknown
            }
            do {
                try upsertAttempt(ResumeAttempt(threadID: thread.id, failedTurnID: failedTurnID, attempt: count,
                                                status: attemptStatus, createdAt: Date(), updatedAt: Date(),
                                                startedTurnID: startedTurnID, message: errorMessage))
                lastError = errorMessage.hasPrefix("Retomada adiada:") ? errorMessage
                    : ResumeRetryPolicy.isTransientActiveWriterMessage(errorMessage)
                    ? "O Codex informou que a conversa ainda tem um writer ativo. O Sentinel tentará novamente com espera progressiva."
                    : attemptStatus == .failed
                        ? "O Codex recusou a retomada: \(errorMessage)"
                        : "A retomada teve resultado indeterminado. O Sentinel verificará o estado antes de tentar novamente."
            } catch {
                // The already-persisted prepared record remains a durable duplicate-prevention marker.
                lastError = "A retomada ficou indeterminada e o estado preparado não pôde ser atualizado. Verifique a conversa no Codex."
            }
        }
    }

    private func reconcileStartedAttempt(with thread: CodexThread) {
        guard let lastTurnID = thread.lastTurnID,
              ["completed", "failed"].contains(thread.lastTurnStatus ?? ""),
              let attempt = attempts.first(where: { $0.threadID == thread.id && $0.startedTurnID == lastTurnID }),
              [.accepted, .unknown, .prepared].contains(attempt.status) else { return }
        recordCompletion(key: attempt.id, status: thread.lastTurnStatus ?? "unknown")
    }

    private func recordCompletion(key: String, status: String) {
        guard let old = attempts.first(where: { $0.id == key }) else { return }
        // A stale waiter timeout must not overwrite a terminal result observed by refresh.
        if status == "unknown", [.completed, .failed].contains(old.status) { return }
        var updated = old
        updated.status = status == "completed" ? .completed : status == "failed" ? .failed : .unknown
        updated.updatedAt = Date()
        do { try upsertAttempt(updated) }
        catch { lastError = "Não foi possível atualizar o diário local da retomada: \(error.localizedDescription)" }
    }

    private func sendNotification(title: String, body: String) {
        guard preferences.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,
                                                                      content: content, trigger: nil))
    }

    private func appendSample(_ sample: UsageSample) {
        usageHistory.append(sample)
        applyRetention()
        save(usageHistory, to: "usage-history.json")
    }

    private func applyRetention() {
        let cutoff = Date().addingTimeInterval(-Double(preferences.historyRetentionDays) * 86_400)
        usageHistory.removeAll { $0.timestamp < cutoff }
    }

    private func upsertAttempt(_ attempt: ResumeAttempt) throws {
        var updatedAttempts = attempts
        if let index = updatedAttempts.firstIndex(where: { $0.id == attempt.id }) { updatedAttempts[index] = attempt }
        else { updatedAttempts.append(attempt) }
        try persistAttemptJournal(updatedAttempts)
        attempts = updatedAttempts
    }

    private func persistAttemptJournal(_ journal: [ResumeAttempt]) throws {
        let data = try encoder.encode(journal)
        let destination = supportDirectory.appendingPathComponent("resume-attempts.json")
        let temporary = supportDirectory.appendingPathComponent(".resume-attempts-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .withoutOverwriting)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            let fileDescriptor = Darwin.open(temporary.path, O_RDONLY)
            guard fileDescriptor >= 0 else { throw posixError() }
            guard Darwin.fsync(fileDescriptor) == 0 else {
                let error = posixError()
                _ = Darwin.close(fileDescriptor)
                throw error
            }
            guard Darwin.close(fileDescriptor) == 0 else { throw posixError() }
            guard Darwin.rename(temporary.path, destination.path) == 0 else { throw posixError() }
            let directoryDescriptor = Darwin.open(supportDirectory.path, O_RDONLY)
            guard directoryDescriptor >= 0 else { throw posixError() }
            guard Darwin.fsync(directoryDescriptor) == 0 else {
                let error = posixError()
                _ = Darwin.close(directoryDescriptor)
                throw error
            }
            _ = Darwin.close(directoryDescriptor)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private func persistPreferences() {
        guard let data = try? encoder.encode(preferences) else { return }
        defaults.set(data, forKey: "preferences")
    }

    private func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        guard let data = try? Data(contentsOf: supportDirectory.appendingPathComponent(filename)) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, to filename: String) {
        guard let data = try? encoder.encode(value) else { return }
        let url = supportDirectory.appendingPathComponent(filename)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
