// swift-tools-version: 6.4
import PackageDescription

// Builds with Command Line Tools alone (no Xcode): `swift build`, `swift test`.
// build.sh wraps the executable into ColimaBar.app.

let package = Package(
    name: "ColimaBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ColimaBar",
            path: "Sources/ColimaBar"
        ),
        .testTarget(
            name: "ColimaBarTests",
            dependencies: ["ColimaBar"],
            path: "Tests/ColimaBarTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
