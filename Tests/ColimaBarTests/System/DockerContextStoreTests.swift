import Foundation
import Testing

@testable import ColimaBar

@Suite struct DockerContextStoreTests {
    private func meta(_ name: String, description: String = "", host: String = "unix:///x.sock") -> String {
        """
        {"Name":"\(name)","Metadata":{"Description":"\(description)"},"Endpoints":{"docker":{"Host":"\(host)"}}}
        """
    }

    private func write(_ text: String, folder: String, in root: TempFolder) throws {
        let dir = "\(root.path)/contexts/meta/\(folder)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: "\(dir)/meta.json"))
    }

    @Test func parsesNameDescriptionAndEndpoint() throws {
        let item = try #require(
            DockerContextStore.parse(meta: Data(meta("remote", description: "Work box", host: "ssh://me@box").utf8)))
        #expect(item == DockerContextItem(name: "remote", description: "Work box", endpoint: "ssh://me@box"))
    }

    @Test func aContextWithoutDescriptionOrEndpointStillParses() throws {
        let item = try #require(DockerContextStore.parse(meta: Data(#"{"Name":"bare"}"#.utf8)))
        #expect(item.description.isEmpty)
        #expect(item.endpoint.isEmpty)
    }

    @Test func badJSONAndUnsafeNamesAreNotContexts() {
        #expect(DockerContextStore.parse(meta: Data("not json".utf8)) == nil)
        #expect(DockerContextStore.parse(meta: Data("[]".utf8)) == nil)
        #expect(DockerContextStore.parse(meta: Data(#"{"Name":""}"#.utf8)) == nil)
        #expect(DockerContextStore.parse(meta: Data(#"{"Name":"-rf"}"#.utf8)) == nil)
        #expect(DockerContextStore.parse(meta: Data(#"{"Name":"a\nb"}"#.utf8)) == nil)
    }

    @Test func listReadsEveryMetaFolderAndAddsDefault() throws {
        let root = try TempFolder()
        try write(meta("colimabar"), folder: "aaa", in: root)
        try write(meta("remote"), folder: "bbb", in: root)
        try write("broken", folder: "ccc", in: root)
        try write(meta("-bad"), folder: "ddd", in: root)
        let names = DockerContextStore.list(configDir: root.path).map(\.name)
        #expect(names == ["colimabar", "default", "remote"])
    }

    @Test func aMissingFolderGivesOnlyDefault() throws {
        let root = try TempFolder()
        #expect(DockerContextStore.list(configDir: root.path + "/none").map(\.name) == ["default"])
    }

    @Test func aFileDoesNotReplaceDefault() throws {
        let root = try TempFolder()
        try write(meta("default", description: "mine"), folder: "aaa", in: root)
        let items = DockerContextStore.list(configDir: root.path)
        #expect(items.count == 1)
        #expect(items[0].description == "mine")
    }

    @Test func configDirFollowsDockerConfig() {
        #expect(DockerContextStore.configDir(env: ["DOCKER_CONFIG": "/d"], home: "/h") == "/d")
        #expect(DockerContextStore.configDir(env: ["DOCKER_CONFIG": ""], home: "/h") == "/h/.docker")
        #expect(DockerContextStore.configDir(env: [:], home: "/h") == "/h/.docker")
    }

    @Test func useRunsDockerContextUseForAKnownName() async {
        let calls = Recorder()
        let items = [
            DockerContextStore.implicitDefault, DockerContextItem(name: "remote", description: "", endpoint: ""),
        ]
        let ok = await DockerContextStore.use("remote", among: items, run: calls.run(status: 0))
        #expect(ok)
        #expect(calls.all == [["docker", "context", "use", "remote"]])
    }

    @Test func useRefusesAnUnknownNameOrAnOptionWithoutRunningAnything() async {
        let calls = Recorder()
        let items = [DockerContextStore.implicitDefault, DockerContextItem(name: "-x", description: "", endpoint: "")]
        #expect(await DockerContextStore.use("nope", among: items, run: calls.run(status: 0)) == false)
        #expect(await DockerContextStore.use("-x", among: items, run: calls.run(status: 0)) == false)
        #expect(calls.all.isEmpty)
    }

    @Test func useReportsAFailedCommand() async {
        let calls = Recorder()
        let ok = await DockerContextStore.use(
            "default", among: [DockerContextStore.implicitDefault], run: calls.run(status: 1))
        #expect(ok == false)
    }
}
