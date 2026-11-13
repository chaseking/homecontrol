// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HomeControl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HomeControl",
            path: "Sources/HomeControl",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
