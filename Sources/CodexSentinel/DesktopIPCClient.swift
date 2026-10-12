import Foundation
import Darwin
import AppKit

/// Compatibility adapter for the locally installed Codex Desktop coordination protocol.
/// Never opens a listener, changes config, takes a writer lock, or retries a dispatched turn.
struct DesktopIPCClient {
    let socketURL: URL
    let timeout: TimeInterval
    private let loadThread: @Sendable (String) async throws -> Void

    init(socketURL: URL, timeout: TimeInterval = 15,
         loadThread: @escaping @Sendable (String) async throws -> Void = { try await DesktopIPCClient.openThread($0) }) {
        self.socketURL = socketURL
        self.timeout = timeout
        self.loadThread = loadThread
    }

    private static func openThread(_ threadID: String) async throws {
        guard UUID(uuidString: threadID) != nil, let url = URL(string: "codex://threads/\(threadID)") else {
            throw AppServerError.resumeDeferred("Identificador de conversa inválido para abrir no Codex.")
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { throw AppServerError.resumeDeferred("Não foi possível carregar a conversa no Codex Desktop.") }
    }

    static func defaultSocketURL(codexHome: String?) -> URL {
        let home = codexHome.flatMap { $0.isEmpty ? nil : $0 }
            ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        return URL(fileURLWithPath: home).appendingPathComponent("ipc/ipc.sock")
    }

    func startContinuation(threadID: String, prompt: String) async throws -> String {
        do { return try await sendContinuation(threadID: threadID, prompt: prompt) }
        catch is DesktopOwnerUnavailable {
            // The desktop may still reserve a thread after unloading its view. Load that exact chat
            // through its normal deep link, then require a live, idle owner before dispatching.
            try await loadThread(threadID)
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(250))
                do { return try await sendContinuation(threadID: threadID, prompt: prompt) }
                catch is DesktopOwnerUnavailable { continue }
            }
            throw AppServerError.resumeDeferred("O Codex ainda não carregou o proprietário da conversa.")
        }
    }

    private func sendContinuation(threadID: String, prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let connection = try DesktopIPCConnection(url: socketURL, timeout: timeout)
                    defer { connection.close() }
                    continuation.resume(returning: try connection.start(threadID: threadID, prompt: prompt))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private final class DesktopIPCConnection {
    private var fd: Int32 = -1
    private var clientID = "uninitialized"
    private let timeout: TimeInterval
    private var dispatched = false
    private static let maximumFrame = 32 * 1024 * 1024

    init(url: URL, timeout: TimeInterval) throws {
        self.timeout = timeout
        var metadata = stat()
        var directory = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFSOCK, metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0,
              lstat(url.deletingLastPathComponent().path, &directory) == 0,
              directory.st_mode & S_IFMT == S_IFDIR, directory.st_uid == getuid(),
              directory.st_mode & 0o022 == 0 else {
            throw AppServerError.resumeDeferred("O canal local seguro do Codex Desktop não está disponível.")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw AppServerError.resumeDeferred("O caminho do canal local do Codex é longo demais.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppServerError.resumeDeferred("Não foi possível abrir o canal local do Codex.") }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close()
            throw AppServerError.resumeDeferred("O Codex Desktop não está conectado ao canal local.")
        }
    }

    deinit { close() }
    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }

    func start(threadID: String, prompt: String) throws -> String {
        let initialized = try request("initialize", version: 0, params: ["clientType": "codex-sentinel"])
        guard let client = initialized["result"] as? [String: Any], let id = client["clientId"] as? String else {
            throw rejection("Inicialização incompatível do Codex Desktop.")
        }
        clientID = id
        let discovery = try request("thread-owner-discovery", version: 1,
                                    params: ["hostId": "local", "conversationId": threadID])
        guard let owner = discovery["handledByClientId"] as? String,
              let capabilities = discovery["result"] as? [String: Any],
              capabilities["supportsUntrustedAppInput"] as? Bool == true else {
            throw rejection("A versão do proprietário da conversa não é compatível.")
        }
        try send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
                  "sourceClientId": clientID, "targetClientIds": [owner],
                  "params": ["conversationId": threadID, "hostId": "local", "following": true]])
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let message = try read(deadline: deadline)
            guard message["type"] as? String == "broadcast",
                  message["method"] as? String == "thread-stream-state-changed",
                  message["sourceClientId"] as? String == owner,
                  let params = message["params"] as? [String: Any],
                  params["conversationId"] as? String == threadID else { continue }
            guard message["version"] as? Int == 11, params["hostId"] as? String == "local",
                  let change = params["change"] as? [String: Any], change["type"] as? String == "snapshot",
                  let state = change["conversationState"] as? [String: Any], state["id"] as? String == threadID,
                  state["resumeState"] as? String == "resumed",
                  let status = state["threadRuntimeStatus"] as? [String: Any], status["type"] as? String == "idle",
                  let requests = state["requests"] as? [Any], requests.isEmpty else {
                throw rejection("A conversa está ocupada, aguarda intervenção ou usa protocolo incompatível no Codex Desktop.")
            }
            break
        }
        // From this point on every transport/protocol error is ambiguous: never send again automatically.
        dispatched = true
        let response = try request("thread-follower-start-turn", version: 2, params: [
            "conversationId": threadID,
            "turnStart": ["request": ["threadId": threadID, "input": [["type": "text", "text": prompt]]],
                          "context": ["inheritThreadSettings": true]]
        ], owner: owner)
        guard let result = response["result"] as? [String: Any],
              let started = result["result"] as? [String: Any],
              let turn = started["turn"] as? [String: Any], let turnID = turn["id"] as? String, !turnID.isEmpty else {
            throw AppServerError.invalidResponse("O Codex Desktop não confirmou o identificador do turno.")
        }
        return turnID
    }

    private func request(_ method: String, version: Int, params: [String: Any], owner: String? = nil) throws -> [String: Any] {
        let id = UUID().uuidString
        var message: [String: Any] = ["type": "request", "requestId": id, "sourceClientId": clientID,
                                      "version": version, "method": method, "params": params,
                                      "timeoutMs": Int(timeout * 1000)]
        if let owner { message["targetClientId"] = owner }
        try send(message)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let response = try read(deadline: deadline)
            guard response["type"] as? String == "response", response["requestId"] as? String == id else { continue }
            guard response["resultType"] as? String == "success" else {
                if !dispatched, method == "thread-owner-discovery", response["error"] as? String == "no-client-found" {
                    throw DesktopOwnerUnavailable()
                }
                // The desktop can fail after accepting a turn, so do not label a dispatched error as retryable.
                throw rejection("O Codex Desktop não confirmou a operação \(method).")
            }
            guard response["method"] as? String == method,
                  owner == nil || response["handledByClientId"] as? String == owner else {
                throw rejection("A resposta do Codex Desktop não corresponde ao proprietário esperado.")
            }
            return response
        }
    }

    private func rejection(_ message: String) -> AppServerError {
        dispatched ? .requestTimedOut("thread-follower-start-turn") : .resumeDeferred(message)
    }

    private func send(_ message: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: message)
        var length = UInt32(body.count).littleEndian
        var data = Data(bytes: &length, count: 4)
        data.append(body)
        let deadline = Date().addingTimeInterval(timeout)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                try ready(POLLOUT, deadline: deadline)
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                guard count > 0 else { throw rejection("O canal local do Codex foi encerrado.") }
                offset += count
            }
        }
    }

    private func read(deadline: Date) throws -> [String: Any] {
        let header = try readBytes(4, deadline: deadline)
        let size = header.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        guard size > 0, size <= Self.maximumFrame else { throw rejection("Quadro incompatível do Codex Desktop.") }
        let data = try readBytes(size, deadline: deadline)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw rejection("Mensagem incompatível do Codex Desktop.")
        }
        return object
    }

    private func readBytes(_ count: Int, deadline: Date) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                try ready(POLLIN, deadline: deadline)
                let received = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                guard received > 0 else { throw rejection("O canal local do Codex foi encerrado.") }
                offset += received
            }
        }
        return data
    }

    private func ready(_ events: Int32, deadline: Date) throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw rejection("O Codex Desktop não respondeu a tempo.") }
        var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
        guard poll(&descriptor, 1, Int32(min(remaining * 1000, Double(Int32.max)))) > 0,
              descriptor.revents & Int16(events) != 0 else {
            throw rejection("O canal local do Codex não respondeu a tempo.")
        }
    }
}

private struct DesktopOwnerUnavailable: Error {}
