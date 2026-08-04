// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Termi",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Termi",
            path: "Sources/Termi",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
