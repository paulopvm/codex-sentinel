import Foundation

@main
struct ResumeRoutingChecks {
    static func main() async throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let client = AppServerClient(executableURL: fixture, codexHome: nil,
            desktopContinuation: { thread, prompt in
                guard thread == "fixture-thread", prompt == "fixture prompt" else {
                    throw AppServerError.invalidResponse("wrong desktop continuation")
                }
                return "desktop-turn"
            })
        try await client.start()
        let turn = try await client.resume(threadID: "fixture-thread", prompt: "fixture prompt")
        guard turn == "desktop-turn" else { fatalError("writer conflict must route to desktop owner") }
        let completion = try await client.waitForTurnCompletion(id: turn)
        guard completion.status == "completed" else { fatalError("desktop completion must be polled") }
        await client.stop()
        print("Desktop owner routing and completion checks passed")
    }
}
