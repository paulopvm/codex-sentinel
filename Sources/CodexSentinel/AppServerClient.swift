import Foundation
import Darwin

enum AppServerError: LocalizedError {
    case executableNotFound
    case processFailed(String)
    case invalidResponse(String)
    case requestFailed(String)
    case resumeDeferred(String)
    case requestTimedOut(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .executableNotFound: "Não encontrei o executável Codex. Confira o caminho nas configurações."
        case .processFailed(let message): message
        case .invalidResponse(let message): "Resposta inválida do Codex: \(message)"
        case .requestFailed(let message): message
        case .resumeDeferred(let message): "Retomada adiada: \(message)"
        case .requestTimedOut(let method): "A chamada \(method) expirou sem resposta do Codex."
        case .timedOut: "O Codex não confirmou a conclusão dentro do tempo esperado."
        }
    }
}

actor AppServerClient {
    private let executableURL: URL
    private let codexHome: String?
    private let desktopContinuation: (@Sendable (String, String) async throws -> String)?
    private var desktopTurns: [String: String] = [:]
    private var resumeCompletions: [String: Task<TurnCompletion, Error>] = [:]
    private var finishedResumeIDs: [String] = []
    private var turnStartSent = false
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var stderr: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<Any, Error>
        let timeoutTask: Task<Void, Never>
    }
    private struct TurnWaiter {
        let continuation: CheckedContinuation<TurnCompletion, Error>
        let timeoutTask: Task<Void, Never>
    }
    private var pending: [Int: PendingRequest] = [:]
    private var turnWaiters: [String: TurnWaiter] = [:]
    private var completedTurns: [String: TurnCompletion] = [:]
    private var started = false
    private var stopped = false
    private var connectionID = UUID()
    private var outputReadTask: Task<Void, Never>?

    struct TurnCompletion: Sendable {
        let status: String
        let error: String?
    }

    init(executableURL: URL, codexHome: String?,
         desktopContinuation: (@Sendable (String, String) async throws -> String)? = nil) {
        self.executableURL = executableURL
        self.codexHome = codexHome
        self.desktopContinuation = desktopContinuation
    }

    func start() async throws {
        guard !stopped else { throw AppServerError.processFailed("O monitoramento do Codex foi encerrado.") }
        guard !started else { return }
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let errors = Pipe()
        child.executableURL = executableURL
        child.arguments = ["app-server", "--listen", "stdio://"]
        var environment = ProcessInfo.processInfo.environment
        if let codexHome, !codexHome.isEmpty { environment["CODEX_HOME"] = codexHome }
        child.environment = environment
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = errors
        do {
            try child.run()
        } catch {
            throw AppServerError.processFailed(error.localizedDescription)
        }
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        stderr = errors.fileHandleForReading
        started = true

        let generation = UUID()
        connectionID = generation
        buffer.removeAll()
        let readHandle = stdout.fileHandleForReading
        // A single reader awaits each chunk before reading the next. Independent callback Tasks
        // can deliver fragments out of order and silently corrupt large JSON responses.
        outputReadTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let data = readHandle.availableData
                guard !data.isEmpty else { break }
                await self?.receive(data, connectionID: generation)
            }
            await self?.processEnded(connectionID: generation)
        }
        stderr?.readabilityHandler = { handle in
            // Drain stderr without retaining content that might contain user data.
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }

        _ = try await request("initialize", params: [
            "clientInfo": ["name": "codex-sentinel", "title": "Codex Sentinel", "version": "0.1.0"],
            "capabilities": ["experimentalApi": false]
        ])
        try await notify("initialized", params: [:])
    }

    func readRateLimits() async throws -> UsageSnapshot {
        let result = try await request("account/rateLimits/read", params: [:])
        let data = try JSONSerialization.data(withJSONObject: result)
        let decoded = try JSONDecoder().decode(RateLimitsResponse.self, from: data)
        return UsageSnapshot(response: decoded, updatedAt: Date())
    }

    func listThreads(cursor: String? = nil) async throws -> ThreadPage {
        var params: [String: Any] = [
            "limit": 100,
            "sortKey": "updated_at",
            "sourceKinds": ["appServer", "cli", "vscode"]
        ]
        if let cursor { params["cursor"] = cursor }
        let result = try await request("thread/list", params: params)
        return try decode(ThreadPage.self, from: result)
    }

    func readThread(id: String) async throws -> ThreadDetailEnvelope {
        let result = try await request("thread/read", params: ["threadId": id, "includeTurns": true])
        return try decode(ThreadDetailEnvelope.self, from: result)
    }

    func resume(threadID: String, prompt: String) async throws -> String {
        guard !stopped else { throw AppServerError.processFailed("O monitoramento do Codex foi encerrado.") }
        // Reading stored threads never acquires a writer. Keep that connection separate
        // from each resumed thread so releasing one cannot interrupt another turn.
        let session = AppServerClient(executableURL: executableURL, codexHome: codexHome,
                                      desktopContinuation: desktopContinuation)
        let turnID: String
        do {
            turnID = try await session.resumeOnConnection(threadID: threadID, prompt: prompt)
        } catch {
            await session.cleanUpFailedResume(threadID: threadID, error: error)
            throw error
        }
        // Start cleanup before returning: a journal write failure or absent UI waiter
        // must not leave a completed thread reserved. This task outlives reader shutdown.
        resumeCompletions[turnID] = Task {
            do {
                let completion = try await session.waitForTurnOnConnection(id: turnID)
                await session.stop()
                retainFinishedResume(id: turnID)
                return completion
            } catch {
                // A timeout is not completion. Keep an active writer alive until a fresh
                // read confirms inactivity, rather than aborting work to release its lease.
                Task { await session.releaseWhenIdle(threadID: threadID) }
                retainFinishedResume(id: turnID)
                throw error
            }
        }
        return turnID
    }

    private func resumeOnConnection(threadID: String, prompt: String) async throws -> String {
        do {
            _ = try await request("thread/resume", params: ["threadId": threadID])
        } catch AppServerError.requestFailed(let message)
            where ResumeRetryPolicy.isTransientActiveWriterMessage(message) {
            // Only a rejected resume is safe to route elsewhere: turn/start was never sent.
            let turnID: String
            if let desktopContinuation {
                turnID = try await desktopContinuation(threadID, prompt)
            } else {
                let desktop = DesktopIPCClient(socketURL: DesktopIPCClient.defaultSocketURL(codexHome: codexHome))
                turnID = try await desktop.startContinuation(threadID: threadID, prompt: prompt)
            }
            desktopTurns[turnID] = threadID
            return turnID
        }
        turnStartSent = true
        let result = try await request("turn/start", params: [
            "threadId": threadID,
            "input": [["type": "text", "text": prompt]]
        ])
        guard let object = result as? [String: Any],
              let turn = object["turn"] as? [String: Any],
              let turnID = turn["id"] as? String else {
            throw AppServerError.invalidResponse("turn/start não retornou o identificador do turno")
        }
        return turnID
    }

    func waitForTurnCompletion(id: String) async throws -> TurnCompletion {
        if let completion = resumeCompletions[id] {
            defer {
                resumeCompletions.removeValue(forKey: id)
                finishedResumeIDs.removeAll { $0 == id }
            }
            return try await completion.value
        }
        return try await waitForTurnOnConnection(id: id)
    }

    private func retainFinishedResume(id: String) {
        // Preserve late-waiter results without unbounded retention if no waiter arrives.
        finishedResumeIDs.append(id)
        if finishedResumeIDs.count > 100 {
            resumeCompletions.removeValue(forKey: finishedResumeIDs.removeFirst())
        }
    }

    private func waitForTurnOnConnection(id: String) async throws -> TurnCompletion {
        if let threadID = desktopTurns[id] {
            defer { desktopTurns.removeValue(forKey: id) }
            let deadline = Date().addingTimeInterval(30 * 60)
            while Date() < deadline {
                try Task.checkCancellation()
                let detail = try await readThread(id: threadID)
                // A separate CLI can reconstruct a live desktop turn as interrupted. Only
                // persisted completion/failure confirms a terminal outcome here.
                if let turn = detail.thread.turns?.first(where: { $0.id == id }),
                   ["completed", "failed"].contains(turn.status) {
                    return TurnCompletion(status: turn.status, error: turn.error?.message)
                }
                try await Task.sleep(for: .seconds(5))
            }
            throw AppServerError.timedOut
        }
        return try await waitForTurn(id: id)
    }

    private func cleanUpFailedResume(threadID: String, error: Error) async {
        if !turnStartSent {
            await stop()
        } else if case AppServerError.requestFailed = error {
            // An explicit rejection confirms no turn was dispatched by this connection.
            await stop()
        } else {
            // Lost/malformed replies can hide an accepted turn. Reconcile without resending.
            Task { await self.releaseWhenIdle(threadID: threadID) }
        }
    }

    private func releaseWhenIdle(threadID: String) async {
        while !stopped {
            guard process?.isRunning == true else { break }
            if let detail = try? await readThread(id: threadID) {
                let status = detail.thread.status
                let lastTurn = detail.thread.turns?.last
                if let status, ["idle", "notLoaded"].contains(status.type),
                   (status.activeFlags ?? []).isEmpty,
                   let lastTurn, ["completed", "failed", "interrupted"].contains(lastTurn.status) {
                    break
                }
            }
            try? await Task.sleep(for: .seconds(5))
        }
        await stop()
    }

    func stop() async {
        stopped = true
        outputReadTask?.cancel()
        outputReadTask = nil
        processEnded(connectionID: connectionID)
        connectionID = UUID()
        output?.readabilityHandler = nil
        stderr?.readabilityHandler = nil
        let child = process
        if child?.isRunning == true { child?.terminate() }
        process = nil
        input = nil
        output = nil
        stderr = nil
        started = false
        // Foundation's waitUntilExit can miss an exit notification when called on a
        // different executor from run(). Poll OS liveness without blocking an executor.
        // SIGTERM is asynchronous; do not report release while the process is still alive.
        if let child {
            let pid = child.processIdentifier
            let deadline = Date().addingTimeInterval(3)
            var escalated = false
            while child.isRunning && Darwin.kill(pid, 0) == 0 {
                if !escalated, Date() >= deadline {
                    Darwin.kill(pid, SIGKILL)
                    escalated = true
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func request(_ method: String, params: [String: Any]) async throws -> Any {
        try await startIfNeeded()
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                await self?.expireRequest(id)
            }
            pending[id] = PendingRequest(method: method, continuation: continuation, timeoutTask: timeoutTask)
            do {
                try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            } catch {
                let request = pending.removeValue(forKey: id)
                request?.timeoutTask.cancel()
                request?.continuation.resume(throwing: error)
            }
        }
    }

    private func notify(_ method: String, params: [String: Any]) async throws {
        try await startIfNeeded()
        try write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func startIfNeeded() async throws {
        if !started { try await start() }
    }

    private func write(_ object: [String: Any]) throws {
        guard let input else { throw AppServerError.processFailed("O canal do Codex foi encerrado.") }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data, connectionID generation: UUID) {
        guard generation == connectionID else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let id = message["id"] as? Int, let request = pending.removeValue(forKey: id) {
                request.timeoutTask.cancel()
                if let error = message["error"] as? [String: Any] {
                    let text = error["message"] as? String ?? "Erro de protocolo sem descrição."
                    request.continuation.resume(throwing: AppServerError.requestFailed(text))
                } else if let result = message["result"] {
                    request.continuation.resume(returning: result)
                } else {
                    request.continuation.resume(throwing: AppServerError.invalidResponse("resposta sem result"))
                }
                continue
            }
            guard message["method"] as? String == "turn/completed",
                  let params = message["params"] as? [String: Any],
                  let turn = params["turn"] as? [String: Any],
                  let id = turn["id"] as? String else { continue }
            let status = turn["status"] as? String ?? "unknown"
            let error = (turn["error"] as? [String: Any])?["message"] as? String
            let completion = TurnCompletion(status: status, error: error)
            if let waiter = turnWaiters.removeValue(forKey: id) {
                waiter.timeoutTask.cancel()
                waiter.continuation.resume(returning: completion)
            } else {
                completedTurns[id] = completion
                if completedTurns.count > 100, let oldest = completedTurns.keys.first { completedTurns.removeValue(forKey: oldest) }
            }
        }
    }

    private func waitForTurn(id: String) async throws -> TurnCompletion {
        if let completed = completedTurns.removeValue(forKey: id) { return completed }
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30 * 60))
                await self?.expireTurn(id)
            }
            turnWaiters[id] = TurnWaiter(continuation: continuation, timeoutTask: timeoutTask)
        }
    }

    private func expireRequest(_ id: Int) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: AppServerError.requestTimedOut(request.method))
    }

    private func expireTurn(_ id: String) {
        guard let waiter = turnWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: AppServerError.timedOut)
    }

    private func processEnded(connectionID generation: UUID) {
        guard generation == connectionID else { return }
        started = false
        let error = AppServerError.processFailed("O canal do Codex foi encerrado.")
        for request in pending.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
        pending.removeAll()
        for waiter in turnWaiters.values {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(throwing: error)
        }
        turnWaiters.removeAll()
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: value)
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw AppServerError.invalidResponse(error.localizedDescription) }
    }
}
