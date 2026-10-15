import Foundation
import Testing

@testable import ColimaBar

@Suite struct DockerConfigTests {
    private func data(_ s: String) -> Data { Data(s.utf8) }
    private func object(_ d: Data?) throws -> [String: Any] {
        let bytes = try #require(d)
        return try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    @Test func readsOnlyTheHelperNamesAndPluginFolders() throws {
        let c = try #require(
            DockerConfig.parse(
                data(
                    """
                    {"auths": {"ghcr.io": {"auth": "c2VjcmV0"}}, "credsStore": "desktop",
                     "credHelpers": {"gcr.io": "gcloud"}, "cliPluginsExtraDirs": ["/x"], "currentContext": "colimabar"}
                    """)))
        #expect(c.credsStore == "desktop")
        #expect(c.credHelpers == ["gcr.io": "gcloud"])
        #expect(c.pluginDirs == ["/x"])
        #expect(c.helperNames == ["desktop", "gcloud"])
    }

    @Test func anEmptyFileIsAnEmptyConfigAndInvalidJSONIsNil() {
        #expect(DockerConfig.parse(Data()) == DockerConfig())
        #expect(DockerConfig.parse(data("  \n")) == DockerConfig())
        #expect(DockerConfig.parse(data("{not json")) == nil)
        #expect(DockerConfig.parse(data("[1, 2]")) == nil)
    }

    @Test func settingTheCredentialHelperKeepsEveryOtherKey() throws {
        let old = #"{"auths": {"a.io": {"auth": "x"}}, "credsStore": "desktop", "currentContext": "colimabar"}"#
        let obj = try object(DockerConfig.settingCredsStore("osxkeychain", in: data(old)))
        #expect(obj["credsStore"] as? String == "osxkeychain")
        #expect(obj["currentContext"] as? String == "colimabar")
        #expect((obj["auths"] as? [String: Any])?["a.io"] != nil)
    }

    @Test func addingAPluginFolderAddsItOnce() throws {
        let once = DockerConfig.addingPluginDir("/opt/x", in: data(#"{"cliPluginsExtraDirs": ["/a"]}"#))
        #expect(try object(once)["cliPluginsExtraDirs"] as? [String] == ["/a", "/opt/x"])
        let twice = DockerConfig.addingPluginDir("/opt/x", in: try #require(once))
        #expect(try object(twice)["cliPluginsExtraDirs"] as? [String] == ["/a", "/opt/x"])
        #expect(
            try object(DockerConfig.addingPluginDir("/opt/x", in: Data()))["cliPluginsExtraDirs"] as? [String] == [
                "/opt/x"
            ])
    }

    @Test func addingAPluginFolderKeepsEveryOtherKey() throws {
        let old = #"{"auths": {"a.io": {"auth": "x"}}, "credsStore": "desktop", "currentContext": "colimabar"}"#
        let obj = try object(DockerConfig.addingPluginDir("/opt/x", in: data(old)))
        #expect(obj["cliPluginsExtraDirs"] as? [String] == ["/opt/x"])
        #expect(obj["credsStore"] as? String == "desktop")
        #expect(obj["currentContext"] as? String == "colimabar")
        #expect((obj["auths"] as? [String: Any])?["a.io"] != nil)
    }

    @Test func invalidJSONIsNeverEdited() {
        #expect(DockerConfig.settingCredsStore("osxkeychain", in: data("{oops")) == nil)
        #expect(DockerConfig.addingPluginDir("/x", in: data("[]")) == nil)
    }
}
