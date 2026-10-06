// swift-tools-version: 6.4
import Foundation
import PackageDescription

// Builds with Command Line Tools alone (no Xcode): `swift build`, `swift test`.
// build.sh wraps the executable into ColimaBar.app.

// Command Line Tools ship swift-testing's macro plugin in a subfolder that
// SwiftPM does not always search, so test builds fail now and then with
// "plugin for module 'TestingMacros' not found". Point the compiler at it
// when it is there. Swift.org toolchains (CI) find it on their own.
let cltTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSettings: [SwiftSetting] =
    FileManager.default.fileExists(atPath: cltTestingPlugins)
    ? [.unsafeFlags(["-plugin-path", cltTestingPlugins])]
    : []

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
            path: "Tests/ColimaBarTests",
            swiftSettings: testSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
