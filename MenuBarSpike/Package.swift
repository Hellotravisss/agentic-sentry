// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SentryMenuBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SentryMenuBar",
            path: "Sources"
        )
    ]
)
