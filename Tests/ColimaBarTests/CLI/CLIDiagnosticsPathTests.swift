import Darwin
import Foundation
import Testing

@testable import ColimaBar

@Suite struct CLIDiagnosticsPathTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let utc = TimeZone(identifier: "UTC")!
    private let name = "ColimaBar-diagnostics-20270115-080000.txt"

    private func resolve(_ argument: String?, cwd: String) -> Result<URL, CLIDiagnosticsPath.Failure> {
        CLIDiagnosticsPath.resolve(argument: argument, cwd: cwd, date: date, timeZone: utc)
    }

    @Test func noPathMeansTheCurrentFolder() throws {
        let tmp = try TempFolder()
        #expect(try resolve(nil, cwd: tmp.path).get().path == "\(tmp.path)/\(name)")
    }

    @Test func aFolderGetsTheFileName() throws {
        let tmp = try TempFolder()
        try FileManager.default.createDirectory(atPath: "\(tmp.path)/out", withIntermediateDirectories: true)
        #expect(try resolve("\(tmp.path)/out", cwd: "/").get().path == "\(tmp.path)/out/\(name)")
        #expect(try resolve("out", cwd: tmp.path).get().path == "\(tmp.path)/out/\(name)")
    }

    @Test func aLinkToAFolderCountsAsAFolder() throws {
        let tmp = try TempFolder()
        try FileManager.default.createDirectory(atPath: "\(tmp.path)/real", withIntermediateDirectories: true)
        symlink("\(tmp.path)/real", "\(tmp.path)/link")
        #expect(try resolve("\(tmp.path)/link", cwd: "/").get().path == "\(tmp.path)/link/\(name)")
    }

    @Test func aNewFileNameIsTheFile() throws {
        let tmp = try TempFolder()
        #expect(try resolve("report.txt", cwd: tmp.path).get().path == "\(tmp.path)/report.txt")
        #expect(try resolve("\(tmp.path)/report.txt", cwd: "/").get().path == "\(tmp.path)/report.txt")
    }

    @Test func anExistingFileIsNeverOverwritten() throws {
        let tmp = try TempFolder()
        FileManager.default.createFile(atPath: "\(tmp.path)/report.txt", contents: Data("keep".utf8))
        #expect(resolve("report.txt", cwd: tmp.path) == .failure(.exists("\(tmp.path)/report.txt")))
        // The file of the same name in the folder counts too.
        FileManager.default.createFile(atPath: "\(tmp.path)/\(name)", contents: nil)
        #expect(resolve(nil, cwd: tmp.path) == .failure(.exists("\(tmp.path)/\(name)")))
    }

    @Test func aLinkAtThePathIsNeverFollowed() throws {
        let tmp = try TempFolder()
        symlink("\(tmp.path)/target.txt", "\(tmp.path)/link.txt")  // points to a file that does not exist
        #expect(resolve("link.txt", cwd: tmp.path) == .failure(.exists("\(tmp.path)/link.txt")))
        #expect(!FileManager.default.fileExists(atPath: "\(tmp.path)/target.txt"))
    }

    @Test func aMissingFolderIsAFailure() throws {
        let tmp = try TempFolder()
        #expect(
            resolve("nothing/report.txt", cwd: tmp.path) == .failure(.folderMissing("\(tmp.path)/nothing")))
        #expect(
            CLIDiagnosticsPath.Failure.folderMissing("/x").message == "The folder /x does not exist.")
    }

    @Test func theMessageNamesTheFile() {
        #expect(CLIDiagnosticsPath.Failure.exists("/x").message == "/x exists. ColimaBar does not overwrite it.")
    }
}
