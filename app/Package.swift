// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ReaderRabbit",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ReaderRabbit",
            path: "Sources/ReaderRabbit"
        ),
    ]
)
