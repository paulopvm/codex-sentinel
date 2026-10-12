import Foundation

@main
struct DesktopIPCChecks {
    static func main() async throws {
        let mode = CommandLine.arguments[2]
        let client = DesktopIPCClient(socketURL: URL(fileURLWithPath: CommandLine.arguments[1]), timeout: 0.5, loadThread: { _ in
            if mode == "load" { return }
            throw AppServerError.resumeDeferred("fixture owner unavailable")
        })
        do {
            let turn = try await client.startContinuation(threadID: "fixture-thread", prompt: "fixture continuation")
            guard ["success", "load"].contains(mode), turn == "fixture-desktop-turn" else { fatalError("unexpected IPC success") }
        } catch {
            switch (mode, error) {
            case ("deferred", AppServerError.resumeDeferred): break
            case ("unknown", AppServerError.requestTimedOut): break
            case ("unknown", AppServerError.invalidResponse): break
            default: throw error
            }
        }
        print("IPC \(mode) check passed")
    }
}
