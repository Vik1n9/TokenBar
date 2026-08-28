// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TokenBar",
            path: "Sources/TokenBar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
