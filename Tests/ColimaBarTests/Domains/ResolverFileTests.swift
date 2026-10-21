import Foundation
import Testing

@testable import ColimaBar

@Suite struct ResolverFileTests {
    @Test func theContentHasTheMarkerTheNameserverAndThePort() {
        #expect(
            ResolverFile.content(port: 25353)
                == "\(ResolverFile.marker)\nnameserver 127.0.0.1\nport 25353\n")
        #expect(ResolverFile.marker.hasPrefix("# Managed by ColimaBar"))
        #expect(!ResolverFile.marker.contains("\n"))
    }

    @Test func ownershipIsTheFirstLine() {
        #expect(ResolverFile.isOurs(ResolverFile.content(port: 20000)))
        #expect(ResolverFile.isOurs(ResolverFile.marker))
        #expect(!ResolverFile.isOurs("nameserver 127.0.0.1\n"))
        #expect(!ResolverFile.isOurs(""))
        #expect(!ResolverFile.isOurs("# other\n" + ResolverFile.marker + "\n"))
        #expect(!ResolverFile.isOurs(ResolverFile.marker + " and more\nnameserver 1.1.1.1\n"))
    }

    @Test func quotingSurvivesSingleQuotes() {
        #expect(ResolverFile.shellQuote("a'b") == "'a'\\''b'")
        #expect(ResolverFile.shellQuote("") == "''")
        #expect(ResolverFile.shellQuote("$(rm -rf /)") == "'$(rm -rf /)'")
    }

    @Test func appleScriptEscapesQuotesBackslashesAndLineBreaks() {
        let s = ResolverFile.appleScript("echo \"a\\b\"\nexit")
        #expect(s == "do shell script \"echo \\\"a\\\\b\\\"\\nexit\" with administrator privileges")
        #expect(!s.contains("\n"))
    }

    @Test func theShellCommandRefusesInvalidInput() {
        #expect(ResolverFile.shellCommand(new: "dev", old: nil, port: 25000) == nil)
        #expect(ResolverFile.shellCommand(new: "a.test; rm -rf /", old: nil, port: 25000) == nil)
        #expect(ResolverFile.shellCommand(new: "a.test", old: "../../etc/passwd", port: 25000) == nil)
        #expect(ResolverFile.shellCommand(new: "a.test", old: nil, port: 80) == nil)
        #expect(ResolverFile.shellCommand(new: "a.test", old: nil, port: 70000) == nil)
        #expect(ResolverFile.shellCommand(new: nil, old: nil, port: 0) == nil)
        #expect(ResolverFile.shellCommand(new: nil, old: "a.test", port: 0) != nil)
        // The valid suffix is normalized before it reaches the text.
        let text = ResolverFile.shellCommand(new: "A.TEST", old: nil, port: 25000)
        #expect(text?.contains("N='a.test'") == true)
    }

    @Test func theCommandHoldsOnlyQuotedValues() throws {
        let text = try #require(ResolverFile.shellCommand(new: "a.test", old: "b.test", port: 26000))
        #expect(text.contains("D='/etc/resolver'"))
        #expect(text.contains("O='b.test'"))
        #expect(text.contains("P=26000"))
        #expect(text.contains("M=" + ResolverFile.shellQuote(ResolverFile.marker)))
    }

    // MARK: Executable

    private struct Box {
        let root: String
        let dir: String
        var path: (String) -> String { { "\(dir)/\($0)" } }
    }

    /// A folder whose name has a space and a quote.
    private func box() throws -> Box {
        let root = NSTemporaryDirectory() + "cb-resolver-\(UUID().uuidString.prefix(8))"
        let dir = "\(root)/it's a dir"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return Box(root: root, dir: dir)
    }

    private func run(_ shell: String) async throws -> (status: Int32, err: String) {
        try await onOwnThread { () -> Result<(status: Int32, err: String), any Error> in
            Result {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", shell]
                let err = Pipe()
                p.standardError = err
                p.standardOutput = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                try p.run()
                let data = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return (p.terminationStatus, String(decoding: data, as: UTF8.self))
            }
        }.get()
    }

    private func cleanup(_ b: Box) { try? FileManager.default.removeItem(atPath: b.root) }

    private func text(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    private func mode(_ path: String) -> Int {
        var info = stat()
        return stat(path, &info) == 0 ? Int(info.st_mode & 0o777) : -1
    }

    @Test func installingWritesTheFileWithMode0644() async throws {
        let b = try box()
        defer { cleanup(b) }
        let cmd = try #require(ResolverFile.shellCommand(dir: b.dir, new: "colima.internal", old: nil, port: 25353))
        let r = try await run(cmd)
        #expect(r.status == 0)
        #expect(text(b.path("colima.internal")) == ResolverFile.content(port: 25353))
        #expect(mode(b.path("colima.internal")) == 0o644)
        #expect(!FileManager.default.fileExists(atPath: b.path(".colima.internal.colimabar-tmp")))
    }

    @Test func installingCreatesTheFolderAndRewritesOurOwnFile() async throws {
        let b = try box()
        defer { cleanup(b) }
        let dir = b.dir + "/new"
        let first = try #require(ResolverFile.shellCommand(dir: dir, new: "a.test", old: nil, port: 25000))
        #expect(try await run(first).status == 0)
        let second = try #require(ResolverFile.shellCommand(dir: dir, new: "a.test", old: nil, port: 26000))
        #expect(try await run(second).status == 0)
        #expect(text("\(dir)/a.test") == ResolverFile.content(port: 26000))
    }

    @Test func aForeignFileGivesExit3AndStaysUnchanged() async throws {
        let b = try box()
        defer { cleanup(b) }
        try "nameserver 127.0.0.1\nport 5353\n".write(toFile: b.path("test"), atomically: true, encoding: .utf8)
        let cmd = try #require(ResolverFile.shellCommand(dir: b.dir, new: "test", old: nil, port: 25000))
        let r = try await run(cmd)
        #expect(r.status == ResolverFile.foreignExit)
        #expect(r.err.contains(ResolverFile.foreignToken))
        #expect(text(b.path("test")) == "nameserver 127.0.0.1\nport 5353\n")
    }

    @Test func aSymlinkAtTheTargetGivesExit3() async throws {
        let b = try box()
        defer { cleanup(b) }
        let victim = b.root + "/victim"
        try ResolverFile.content(port: 1).write(toFile: victim, atomically: true, encoding: .utf8)
        symlink(victim, b.path("a.test"))
        let cmd = try #require(ResolverFile.shellCommand(dir: b.dir, new: "a.test", old: nil, port: 25000))
        #expect(try await run(cmd).status == ResolverFile.foreignExit)
        #expect(text(victim) == ResolverFile.content(port: 1))
    }

    @Test func changingTheSuffixRemovesOnlyAnOldFileOfOurs() async throws {
        let b = try box()
        defer { cleanup(b) }
        try ResolverFile.content(port: 25000).write(toFile: b.path("old.test"), atomically: true, encoding: .utf8)
        let cmd = try #require(ResolverFile.shellCommand(dir: b.dir, new: "new.test", old: "old.test", port: 25000))
        #expect(try await run(cmd).status == 0)
        #expect(!FileManager.default.fileExists(atPath: b.path("old.test")))
        #expect(text(b.path("new.test")) == ResolverFile.content(port: 25000))
        // A foreign old file stays.
        try "nameserver 1.1.1.1\n".write(toFile: b.path("other.test"), atomically: true, encoding: .utf8)
        let again = try #require(
            ResolverFile.shellCommand(dir: b.dir, new: "third.test", old: "other.test", port: 25000))
        #expect(try await run(again).status == 0)
        #expect(text(b.path("other.test")) == "nameserver 1.1.1.1\n")
        #expect(text(b.path("third.test")) != nil)
    }

    @Test func aForeignNewFileKeepsTheOldFileToo() async throws {
        let b = try box()
        defer { cleanup(b) }
        try ResolverFile.content(port: 25000).write(toFile: b.path("old.test"), atomically: true, encoding: .utf8)
        try "x\n".write(toFile: b.path("new.test"), atomically: true, encoding: .utf8)
        let cmd = try #require(ResolverFile.shellCommand(dir: b.dir, new: "new.test", old: "old.test", port: 25000))
        #expect(try await run(cmd).status == ResolverFile.foreignExit)
        #expect(text(b.path("old.test")) != nil)
    }

    @Test func removingDeletesOurFileAndKeepsAForeignOne() async throws {
        let b = try box()
        defer { cleanup(b) }
        try ResolverFile.content(port: 25000).write(toFile: b.path("a.test"), atomically: true, encoding: .utf8)
        try "keep\n".write(toFile: b.path("b.test"), atomically: true, encoding: .utf8)
        symlink(b.path("b.test"), b.path("c.test"))
        for name in ["a.test", "b.test", "c.test", "missing.test"] {
            let cmd = try #require(ResolverFile.shellCommand(dir: b.dir, new: nil, old: name, port: 0))
            #expect(try await run(cmd).status == 0)
        }
        #expect(!FileManager.default.fileExists(atPath: b.path("a.test")))
        #expect(text(b.path("b.test")) == "keep\n")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: b.path("c.test"))) != nil)
    }

    @Test func theMarkerSurvivesTheShellRoundTrip() async throws {
        // The marker has parentheses, dots and spaces: the file must still be ours.
        let b = try box()
        defer { cleanup(b) }
        let cmd = try #require(ResolverFile.shellCommand(dir: b.dir, new: "a.test", old: nil, port: 25000))
        #expect(try await run(cmd).status == 0)
        #expect(ResolverFile.isOurs(text(b.path("a.test")) ?? ""))
        #expect(ResolverInstaller.inspect("a.test", dir: b.dir) == .ours)
    }

    @Test func theNewFileIsWrittenBeforeTheOldOneIsRemoved() async throws {
        let b = try box()
        defer { cleanup(b) }
        try ResolverFile.content(port: 25000).write(toFile: b.path("old.test"), atomically: true, encoding: .utf8)
        // The folder cannot be written: the new file fails, so the old file must stay.
        chmod(b.dir, 0o555)
        defer { chmod(b.dir, 0o755) }
        let cmd = try #require(ResolverFile.shellCommand(dir: b.dir, new: "new.test", old: "old.test", port: 25000))
        #expect(try await run(cmd).status != 0)
        chmod(b.dir, 0o755)
        #expect(text(b.path("old.test")) == ResolverFile.content(port: 25000))
        #expect(!FileManager.default.fileExists(atPath: b.path("new.test")))
        let order = cmd.range(of: "/bin/mv -f")?.lowerBound
        let removal = cmd.range(of: "/bin/rm -f \"$D/$O\"")?.lowerBound
        #expect(try #require(order) < #require(removal))
    }

    @Test func aFailureAfterTheTemporaryFileLeavesNoTemporaryFile() async throws {
        let b = try box()
        defer { cleanup(b) }
        let cmd = try #require(ResolverFile.shellCommand(dir: b.dir, new: "a.test", old: nil, port: 25000))
        #expect(cmd.contains("trap "))
        // Force the rename to fail after the temporary file exists.
        let broken = cmd.replacingOccurrences(of: "/bin/mv -f", with: "/usr/bin/false #")
        #expect(try await run(broken).status != 0)
        #expect(!FileManager.default.fileExists(atPath: b.path(".a.test.colimabar-tmp")))
        #expect(!FileManager.default.fileExists(atPath: b.path("a.test")))
    }

    @Test func aTemporaryFileThatIsALinkIsReplacedNotFollowed() async throws {
        let b = try box()
        defer { cleanup(b) }
        let victim = b.root + "/victim"
        try "keep\n".write(toFile: victim, atomically: true, encoding: .utf8)
        symlink(victim, b.path(".a.test.colimabar-tmp"))
        let cmd = try #require(ResolverFile.shellCommand(dir: b.dir, new: "a.test", old: nil, port: 25000))
        #expect(try await run(cmd).status == 0)
        #expect(text(victim) == "keep\n")
        #expect(text(b.path("a.test")) == ResolverFile.content(port: 25000))
        #expect(!FileManager.default.fileExists(atPath: b.path(".a.test.colimabar-tmp")))
    }

    @Test func theSameSuffixAsOldAndNewKeepsTheFile() async throws {
        let b = try box()
        defer { cleanup(b) }
        try ResolverFile.content(port: 25000).write(toFile: b.path("a.test"), atomically: true, encoding: .utf8)
        let cmd = try #require(ResolverFile.shellCommand(dir: b.dir, new: "a.test", old: "a.test", port: 26000))
        #expect(try await run(cmd).status == 0)
        #expect(text(b.path("a.test")) == ResolverFile.content(port: 26000))
    }

    @Test func aDanglingLinkAtTheTargetGivesExit3() async throws {
        let b = try box()
        defer { cleanup(b) }
        symlink(b.root + "/nowhere", b.path("a.test"))
        let cmd = try #require(ResolverFile.shellCommand(dir: b.dir, new: "a.test", old: nil, port: 25000))
        #expect(try await run(cmd).status == ResolverFile.foreignExit)
        #expect(!FileManager.default.fileExists(atPath: b.root + "/nowhere"))
    }

    @Test func aDirectoryAtTheNewOrOldNameIsLeftAlone() async throws {
        let b = try box()
        defer { cleanup(b) }
        try FileManager.default.createDirectory(atPath: b.path("new.test"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: b.path("old.test"), withIntermediateDirectories: true)
        let asNew = try #require(ResolverFile.shellCommand(dir: b.dir, new: "new.test", old: nil, port: 25000))
        #expect(try await run(asNew).status == ResolverFile.foreignExit)
        let asOld = try #require(ResolverFile.shellCommand(dir: b.dir, new: nil, old: "old.test", port: 0))
        #expect(try await run(asOld).status == 0)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: b.path("new.test"), isDirectory: &isDir) && isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: b.path("old.test"), isDirectory: &isDir) && isDir.boolValue)
    }
}
