import Foundation

@main
struct WriterReleaseChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = AppServerClient(executableURL: URL(fileURLWithPath: CommandLine.arguments[1]), codexHome: directory.path)
        try await client.start()
        let first = try await client.resume(threadID: "first", prompt: "fixture")
        try Data().write(to: directory.appendingPathComponent("first.finish"))
        _ = try await client.waitForTurnCompletion(id: first)
        // Removing process cleanup would strand the user's desktop behind this lease.
        try await requireReleased("first", in: directory)
        _ = try await client.readRateLimits()

        let second = try await client.resume(threadID: "second", prompt: "fixture")
        let third = try await client.resume(threadID: "third", prompt: "fixture")
        try Data().write(to: directory.appendingPathComponent("second.finish"))
        _ = try await client.waitForTurnCompletion(id: second)
        try await requireReleased("second", in: directory)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("third.lease").path) else {
            throw Failure(message: "finishing one resume interrupted another writer")
        }
        try Data().write(to: directory.appendingPathComponent("third.finish"))
        _ = try await client.waitForTurnCompletion(id: third)
        try await requireReleased("third", in: directory)

        // Completion must release the writer even if journal persistence prevents attaching a waiter.
        let unobserved = try await client.resume(threadID: "unobserved", prompt: "fixture")
        try Data().write(to: directory.appendingPathComponent("unobserved.finish"))
        try await requireReleased("unobserved", in: directory)
        _ = try await client.waitForTurnCompletion(id: unobserved)

        for status in ["failed", "interrupted"] {
            let turn = try await client.resume(threadID: status, prompt: "fixture")
            try Data().write(to: directory.appendingPathComponent(status + ".finish"))
            let completion = try await client.waitForTurnCompletion(id: turn)
            guard completion.status == status else { throw Failure(message: "lost terminal status") }
            try await requireReleased(status, in: directory)
        }
        do {
            _ = try await client.resume(threadID: "rejected", prompt: "fixture")
            throw Failure(message: "rejected turn accepted")
        } catch AppServerError.requestFailed { }
        try await requireReleased("rejected", in: directory)
        _ = try await client.readRateLimits()

        do {
            _ = try await client.resume(threadID: "ambiguous", prompt: "fixture")
            throw Failure(message: "malformed turn accepted")
        } catch AppServerError.invalidResponse { }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("ambiguous.polled").path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("ambiguous.lease").path) else {
            throw Failure(message: "ambiguous dispatch killed an active writer")
        }
        try Data().write(to: directory.appendingPathComponent("ambiguous.finish"))
        try await requireReleased("ambiguous", in: directory)

        let surviving = try await client.resume(threadID: "surviving", prompt: "fixture")
        await client.stop()
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("surviving.lease").path) else {
            throw Failure(message: "reader shutdown killed a resumed turn")
        }
        try Data().write(to: directory.appendingPathComponent("surviving.finish"))
        _ = try await client.waitForTurnCompletion(id: surviving)
        try await requireReleased("surviving", in: directory)
        do {
            _ = try await client.resume(threadID: "after-stop", prompt: "fixture")
            throw Failure(message: "stopped monitoring started new work")
        } catch AppServerError.processFailed { }
        print("Writer release checks passed: completion, independent resumes, absent waiter, failure, interruption, rejection, ambiguous dispatch, reader shutdown")
    }

    static func requireReleased(_ thread: String, in directory: URL) async throws {
        let lease = directory.appendingPathComponent(thread + ".lease")
        for _ in 0..<400 {
            if !FileManager.default.fileExists(atPath: lease.path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(message: "completed resume still holds writer lease for \(thread)")
    }

    struct Failure: Error { let message: String }
}
