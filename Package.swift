// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexSentinel",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexSentinel", targets: ["CodexSentinel"])
    ],
    targets: [
        .executableTarget(name: "CodexSentinel", path: "Sources/CodexSentinel")
    ],
    swiftLanguageModes: [.v5]
)
