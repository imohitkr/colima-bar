import Foundation
import Testing

@testable import ColimaBar

@Suite struct DockerHostLineTests {
    @Test func matchesEqualsWithoutSpaces() {
        #expect(Routing.dockerHostValue("docker.host=unix:///tmp/a.sock") == "unix:///tmp/a.sock")
    }

    @Test func matchesEqualsWithSpaces() {
        #expect(Routing.dockerHostValue("docker.host = tcp://remote:2375") == "tcp://remote:2375")
    }

    @Test func matchesColonSeparator() {
        #expect(Routing.dockerHostValue("docker.host:tcp://remote:2375") == "tcp://remote:2375")
        #expect(Routing.dockerHostValue("docker.host : tcp://remote:2375") == "tcp://remote:2375")
    }

    @Test func matchesLeadingWhitespace() {
        #expect(Routing.dockerHostValue("   docker.host=tcp://remote:2375") == "tcp://remote:2375")
        #expect(Routing.dockerHostValue("\tdocker.host=tcp://remote:2375  ") == "tcp://remote:2375")
    }

    @Test func ignoresCommentsAndOtherKeys() {
        #expect(Routing.dockerHostValue("#docker.host=tcp://remote:2375") == nil)
        #expect(Routing.dockerHostValue("  # docker.host=tcp://remote:2375") == nil)
        #expect(Routing.dockerHostValue("docker.hostname=foo") == nil)
        #expect(Routing.dockerHostValue("ryuk.disabled=true") == nil)
        #expect(Routing.dockerHostValue("docker.host") == nil)
    }
}

@Suite struct RuntimeSocketTests {
    @Test func dockerOrUnknownRuntimeHasSocket() {
        #expect(ColimaModel.hasDockerSocket(runtime: "docker"))
        #expect(ColimaModel.hasDockerSocket(runtime: ""))
    }

    @Test func otherRuntimesHaveNoSocket() {
        #expect(!ColimaModel.hasDockerSocket(runtime: "containerd"))
        #expect(!ColimaModel.hasDockerSocket(runtime: "incus"))
    }
}

@Suite struct OnDiskVersionTests {
    @Test func readsVersionFromInfoPlistOnDisk() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreFixTests-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let write = { (version: String) in
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try write("1.0.0")
        #expect(AppDelegate.onDiskVersion(of: bundle) == "1.0.0")
        // A later read sees the replaced file, not a cached copy.
        try write("1.1.0")
        #expect(AppDelegate.onDiskVersion(of: bundle) == "1.1.0")
    }

    @Test func missingPlistGivesNil() {
        let bundle = URL(fileURLWithPath: "/nonexistent/ColimaBar.app")
        #expect(AppDelegate.onDiskVersion(of: bundle) == nil)
    }
}
