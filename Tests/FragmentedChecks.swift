import Foundation
@main struct FragmentedChecks {
    static func main() async throws {
        let client = AppServerClient(executableURL: URL(fileURLWithPath: CommandLine.arguments[1]), codexHome: nil)
        try await client.start()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    let id = "fixture-\(index)"
                    let detail = try await client.readThread(id: id)
                    guard detail.thread.turns?.last?.id == id else { fatalError("fragmented responses must preserve request identity") }
                }
            }
            try await group.waitForAll()
        }
        await client.stop()
        do {
            _ = try await client.readThread(id: "fixture-after-stop")
            fatalError("a stopped client must not silently restart Codex")
        } catch AppServerError.processFailed { }
        print("12 concurrent fragmented responses and stopped-client checks passed")
    }
}
