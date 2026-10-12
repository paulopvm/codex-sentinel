import Foundation

@main
struct AppServerChecks {
    static func main() async throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let client = AppServerClient(executableURL: executable, codexHome: nil)
        try await client.start()
        let usage = try await client.readRateLimits()
        let page = try await client.listThreads()
        guard let summary = page.data.first else { throw CheckFailure(message: "fake server thread list was empty") }
        let detail = try await client.readThread(id: summary.id)
        let thread = CodexThread.combine(summary, detail: detail)
        let resumedTurnID = try await client.resume(threadID: "fixture-thread", prompt: "fixture prompt")
        let completion = try await client.waitForTurnCompletion(id: resumedTurnID)
        guard usage.windows.count == 2,
              usage.windows[0].window.usedPercent == 12,
              thread.readiness == .rateLimited,
              thread.lastTurnID == "fixture-turn",
              completion.status == "completed" else {
            throw CheckFailure(message: "App Server JSON-RPC read flow did not preserve the fixture data")
        }
        await client.stop()
        print("App Server protocol check passed against a fake executable and fixture thread IDs")
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
