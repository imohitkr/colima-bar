import CryptoKit
import Foundation
import Testing

@testable import ColimaBar

@Suite struct HelperImageTests {
    /// The data of each file of a simple tar archive, by name.
    private func files(_ tar: Data) -> [String: Data] {
        var out: [String: Data] = [:]
        var pos = 0
        while pos + 512 <= tar.count {
            let block = Array(tar[pos..<(pos + 512)])
            if TarHeader.isZero(block) { break }
            guard let h = TarHeader.parse(block) else { break }
            pos += 512
            out[h.name] = tar[pos..<(pos + Int(h.size))]
            pos += Int(TarHeader.padded(h.size))
        }
        return out
    }

    @Test func theArchiveHoldsTheThreeFilesOfADockerSave() {
        #expect(Set(files(HelperImage.archive(arch: "arm64")).keys) == ["manifest.json", "config.json", "layer.tar"])
    }

    @Test func theManifestNamesTheTagTheConfigAndTheLayer() throws {
        let manifest = try #require(files(HelperImage.archive(arch: "arm64"))["manifest.json"])
        let list = try #require(JSONSerialization.jsonObject(with: manifest) as? [[String: Any]])
        #expect(list.count == 1)
        #expect(list[0]["Config"] as? String == "config.json")
        #expect(list[0]["RepoTags"] as? [String] == ["colimabar-helper:1"])
        #expect(list[0]["Layers"] as? [String] == ["layer.tar"])
    }

    @Test func theDiffIDIsTheSHA256OfTheLayer() throws {
        let parts = files(HelperImage.archive(arch: "arm64"))
        let layer = try #require(parts["layer.tar"])
        let configData = try #require(parts["config.json"])
        let config = try #require(JSONSerialization.jsonObject(with: configData) as? [String: Any])
        let rootfs = try #require(config["rootfs"] as? [String: Any])
        let expected = "sha256:" + SHA256.hash(data: layer).map { String(format: "%02x", $0) }.joined()
        #expect(rootfs["diff_ids"] as? [String] == [expected])
        #expect(config["os"] as? String == "linux" && config["architecture"] as? String == "arm64")
    }

    @Test func theLayerHasTheEmptyFolderV() throws {
        let layer = try #require(files(HelperImage.archive(arch: "amd64"))["layer.tar"])
        var s = TarScanner()
        try s.feed(layer)
        #expect(s.isComplete && s.entryCount == 1 && !s.sawContent)
    }

    @Test func theBytesDependOnlyOnTheArchitecture() {
        #expect(HelperImage.archive(arch: "arm64") == HelperImage.archive(arch: "arm64"))
        #expect(HelperImage.archive(arch: "arm64") != HelperImage.archive(arch: "amd64"))
    }

    @Test func theArchiveIsSmall() {
        #expect(HelperImage.archive(arch: "arm64").count < 8 * 1024)
    }

    @Test(arguments: [("aarch64", "arm64"), ("x86_64", "amd64"), ("arm64", "arm64"), ("riscv64", "riscv64")])
    func theArchitectureMapsToTheImageName(info: String, image: String) {
        #expect(HelperImage.architecture(info: info) == image)
    }

    @Test func anUnknownArchitectureFallsBackToArm64() {
        #expect(HelperImage.architecture(info: nil) == "arm64")
    }

    @Test func theContainerBodyMountsTheVolumeAtV() throws {
        let body = HelperImage.containerBody(volume: "pgdata", readOnly: true)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let host = try #require(json["HostConfig"] as? [String: Any])
        let mounts = try #require(host["Mounts"] as? [[String: Any]])
        #expect(mounts.count == 1)
        #expect(mounts[0]["Source"] as? String == "pgdata" && mounts[0]["Target"] as? String == "/v")
        #expect(mounts[0]["ReadOnly"] as? Bool == true && mounts[0]["Type"] as? String == "volume")
        #expect(json["Image"] as? String == "colimabar-helper:1" && json["NetworkDisabled"] as? Bool == true)
    }

    @Test func aRestoreMountIsWritable() throws {
        let body = HelperImage.containerBody(volume: "x", readOnly: false)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let mounts = try #require((json["HostConfig"] as? [String: Any])?["Mounts"] as? [[String: Any]])
        #expect(mounts[0]["ReadOnly"] as? Bool == false)
    }

    @Test func theContainerHasBothLabels() throws {
        let body = HelperImage.containerBody(volume: "x", readOnly: true)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let labels = json["Labels"] as? [String: String]
        #expect(labels == ["com.imohitkr.colimabar.helper": "1", "com.imohitkr.colimabar.helper.kind": "volume"])
    }

    @Test func onlyTheHelperLabelMarksAHelper() {
        #expect(HelperImage.isHelper(labels: ["com.imohitkr.colimabar.helper": "1"]))
        #expect(!HelperImage.isHelper(labels: ["com.imohitkr.colimabar.helper": "0"]))
        #expect(!HelperImage.isHelper(labels: nil))
    }

    @Test func theLabelFilterNamesBothLabels() {
        let filter = HelperImage.labelFilter
        #expect(filter.contains("com.imohitkr.colimabar.helper=1"))
        #expect(filter.contains("com.imohitkr.colimabar.helper.kind=volume"))
    }
}
