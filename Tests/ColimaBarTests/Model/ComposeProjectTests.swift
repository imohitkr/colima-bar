import Foundation
import Testing

@testable import ColimaBar

@Suite struct ComposeProjectTests {
    private func labels(
        name: String = "web", dir: String? = "/Users/ab/web", files: String? = "/Users/ab/web/compose.yaml",
        env: String? = nil
    ) -> [String: String] {
        var l = ["com.docker.compose.project": name]
        if let dir { l["com.docker.compose.project.working_dir"] = dir }
        if let files { l["com.docker.compose.project.config_files"] = files }
        if let env { l["com.docker.compose.project.environment_file"] = env }
        return l
    }

    @Test func validLabelsGiveAProject() {
        let p = ComposeProject.from(labels: labels())
        #expect(
            p
                == ComposeProject(
                    name: "web", directory: "/Users/ab/web", configFiles: ["/Users/ab/web/compose.yaml"],
                    environmentFiles: []))
    }

    @Test(arguments: ["", "Web", "-web", "_web", "we b", "web;rm", "web/x", "web.x", String(repeating: "a", count: 64)])
    func aBadNameGivesNoProject(name: String) {
        #expect(ComposeProject.from(labels: labels(name: name)) == nil, "\(name)")
    }

    @Test func theLongestNameIsValid() {
        let name = "a" + String(repeating: "b", count: 62)
        #expect(ComposeProject.from(labels: labels(name: name))?.name == name)
        #expect(ComposeProject.from(labels: labels(name: "a_b-1"))?.name == "a_b-1")
    }

    @Test func aRelativePathGivesNoProject() {
        #expect(ComposeProject.from(labels: labels(dir: "web")) == nil)
        #expect(ComposeProject.from(labels: labels(files: "compose.yaml")) == nil)
        #expect(ComposeProject.from(labels: labels(files: "/a/compose.yaml,b.yaml")) == nil)
    }

    @Test func aPathWithDotDotGivesNoProject() {
        #expect(ComposeProject.from(labels: labels(dir: "/Users/ab/../web")) == nil)
        #expect(ComposeProject.from(labels: labels(files: "/Users/ab/web/../c.yaml")) == nil)
    }

    @Test func aPathWithAControlCharacterGivesNoProject() {
        #expect(ComposeProject.from(labels: labels(dir: "/Users/ab/web\n--x")) == nil)
        #expect(ComposeProject.from(labels: labels(files: "/a/b.yaml\u{0}")) == nil)
        #expect(ComposeProject.from(labels: labels(env: "/a/.env\r")) == nil)
    }

    @Test func aPathOfMoreThan1024BytesGivesNoProject() {
        let long = "/" + String(repeating: "a", count: 1024)
        #expect(ComposeProject.from(labels: labels(dir: long)) == nil)
        let fits = "/" + String(repeating: "a", count: 1023)
        #expect(ComposeProject.from(labels: labels(dir: fits))?.directory == fits)
    }

    @Test func aPathIsInItsStandardForm() {
        let p = ComposeProject.from(labels: labels(dir: "/Users//ab/./web/", files: "/Users/ab/web//compose.yaml"))
        #expect(p?.directory == "/Users/ab/web")
        #expect(p?.configFiles == ["/Users/ab/web/compose.yaml"])
    }

    @Test func aCommaSplitsTheFiles() {
        let p = ComposeProject.from(labels: labels(files: "/a/one.yaml,/a/two.yaml"))
        #expect(p?.configFiles == ["/a/one.yaml", "/a/two.yaml"])
    }

    @Test func noFilesGiveNoProject() {
        #expect(ComposeProject.from(labels: labels(files: nil)) == nil)
        #expect(ComposeProject.from(labels: labels(files: "")) == nil)
        #expect(ComposeProject.from(labels: labels(files: "/a/one.yaml,")) == nil)
    }

    @Test func atMost16FilesGiveAProject() {
        let list = { (n: Int) in (1...n).map { "/a/\($0).yaml" }.joined(separator: ",") }
        #expect(ComposeProject.from(labels: labels(files: list(16)))?.configFiles.count == 16)
        #expect(ComposeProject.from(labels: labels(files: list(17))) == nil)
    }

    @Test func aMissingLabelGivesNoProject() {
        #expect(ComposeProject.from(labels: [:]) == nil)
        #expect(ComposeProject.from(labels: labels(dir: nil)) == nil)
    }

    @Test func anEnvFileIsKept() {
        #expect(
            ComposeProject.from(labels: labels(env: "/Users/ab/web/.env"))?.environmentFiles == ["/Users/ab/web/.env"])
        #expect(ComposeProject.from(labels: labels(env: ""))?.environmentFiles == [])
        #expect(ComposeProject.from(labels: labels(env: "rel/.env")) == nil)
    }

    @Test func everyEnvFileIsKeptInOrder() {
        let p = ComposeProject.from(labels: labels(env: "/a/.env,/a/.env.local"))
        #expect(p?.environmentFiles == ["/a/.env", "/a/.env.local"])
    }

    @Test func oneBadEnvFileGivesNoProject() {
        #expect(ComposeProject.from(labels: labels(env: "/a/.env,rel/.env")) == nil)
        #expect(ComposeProject.from(labels: labels(env: "/a/.env,../x")) == nil)
        #expect(ComposeProject.from(labels: labels(env: "/a/.env,")) == nil)
    }

    @Test func atMost16EnvFilesGiveAProject() {
        let list = { (n: Int) in (1...n).map { "/a/\($0).env" }.joined(separator: ",") }
        #expect(ComposeProject.from(labels: labels(env: list(16)))?.environmentFiles.count == 16)
        #expect(ComposeProject.from(labels: labels(env: list(17))) == nil)
    }

    @Test(arguments: ["app\n", "app\r\n", "\napp"])
    func aNameWithALineBreakGivesNoProject(name: String) {
        #expect(!ComposeProject.isValid(name: name), "\(name.debugDescription)")
        #expect(ComposeProject.from(labels: labels(name: name)) == nil)
    }

    @Test func ctlArgsAreNameFolderEnvCountEnvFilesAndFiles() {
        let p = ComposeProject.from(labels: labels(files: "/a/one.yaml,/a/two.yaml", env: "/a/.env,/a/.env2"))
        #expect(
            p?.ctlArgs() == ["web", "/Users/ab/web", "2", "/a/.env", "/a/.env2", "/a/one.yaml", "/a/two.yaml"])
        let plain = ComposeProject.from(labels: labels())
        #expect(plain?.ctlArgs() == ["web", "/Users/ab/web", "0", "/Users/ab/web/compose.yaml"])
    }

    @Test func missingFilesListsTheFilesThatDoNotExist() {
        let p = ComposeProject.from(labels: labels(files: "/a/one.yaml,/a/two.yaml", env: "/a/.env"))
        #expect(p?.missingFiles { $0 == "/a/one.yaml" } == ["/a/two.yaml", "/a/.env"])
        #expect(p?.missingFiles { _ in true } == [])
    }
}
