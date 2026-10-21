import Testing

@testable import ColimaBar

@Suite struct LogFileSizesTests {
    private let a = String(repeating: "a1", count: 32)
    private let b = String(repeating: "b2", count: 32)
    private func line(_ size: Any, _ id: String) -> String {
        "\(size) /var/lib/docker/containers/\(id)/\(id)-json.log"
    }
    private let marker = "colimabar-status=0"

    @Test func parsesTheSizeOfEachLog() {
        let out = [line(180, a), line(0, b), marker].joined(separator: "\n") + "\n"
        #expect(LogFileSizes.parse(status: 0, out: out) == [a: 180, b: 0])
    }

    @Test func aMissingMarkerGivesNil() {
        #expect(LogFileSizes.parse(status: 0, out: line(1, a) + "\n") == nil)
    }

    @Test func aFailedSSHGivesNil() {
        #expect(LogFileSizes.parse(status: 1, out: line(1, a) + "\n" + marker) == nil)
    }

    @Test func noLogFilesGivesAnEmptyMap() {
        #expect(LogFileSizes.parse(status: 0, out: marker + "\n") == [:])
    }

    @Test(arguments: [
        "1 /var/lib/docker/containers/\(String(repeating: "a1", count: 32))/\(String(repeating: "b2", count: 32))-json.log",
        "1 /var/lib/docker/containers/\(String(repeating: "A1", count: 32))/\(String(repeating: "A1", count: 32))-json.log",
        "1 /var/lib/docker/containers/\(String(repeating: "a", count: 63))/\(String(repeating: "a", count: 63))-json.log",
        "1 /var/lib/docker/containers/\(String(repeating: "a1", count: 32))/\(String(repeating: "a1", count: 32))-json.log.1",
        "1 /var/lib/docker/containers/\(String(repeating: "a1", count: 32))/../x-json.log",
        "1 /x/var/lib/docker/containers/\(String(repeating: "a1", count: 32))/\(String(repeating: "a1", count: 32))-json.log",
        "1 /var/lib/docker/containers/\(String(repeating: "a1", count: 32))/\(String(repeating: "a1", count: 32))-json.log/extra",
        "abc /var/lib/docker/containers/\(String(repeating: "a1", count: 32))/\(String(repeating: "a1", count: 32))-json.log",
        "-5 /var/lib/docker/containers/\(String(repeating: "a1", count: 32))/\(String(repeating: "a1", count: 32))-json.log",
    ])
    func rejectsPathsThatAreNotExactlyTheLogOfOneContainer(bad: String) {
        #expect(LogFileSizes.parse(status: 0, out: bad + "\n" + marker) == [:], "\(bad)")
    }

    @Test func stopsAfterMaxLines() {
        var lines: [String] = []
        for n in 0..<(LogFileSizes.maxLines + 5) {
            let id = String(format: "%064x", n)
            lines.append(line(1, id))
        }
        let sizes = LogFileSizes.parse(status: 0, out: (lines + [marker]).joined(separator: "\n"))
        #expect(sizes?.count == LogFileSizes.maxLines)
    }

    @Test func theCommandUsesTheProfileAndSudoWithoutAPrompt() {
        #expect(
            LogFileSizes.command(profile: "work")
                == ["colima", "ssh", "--profile", "work", "--", "sudo", "-n", "sh", "-c", LogFileSizes.vmScript])
    }

    @Test func theScriptHoldsNoContainerText() {
        #expect(!LogFileSizes.vmScript.contains("\\("))
        #expect(LogFileSizes.vmScript.hasSuffix("echo colimabar-status=0"))
        #expect(LogFileSizes.vmScript.hasPrefix("for f in /var/lib/docker/containers/*/*-json.log;"))
    }

    @Test func validIDsAreSixtyFourLowercaseHexCharacters() {
        #expect(LogFileSizes.isValidID(a))
        #expect(!LogFileSizes.isValidID(String(a.dropLast())))
        #expect(!LogFileSizes.isValidID(a + "a"))
        #expect(!LogFileSizes.isValidID(a.uppercased()))
        #expect(!LogFileSizes.isValidID(String(repeating: "g", count: 64)))
        #expect(!LogFileSizes.isValidID(""))
    }

    @Test func thePathIsBuiltFromAValidIDOnly() {
        #expect(LogFileSizes.path(id: a) == "/var/lib/docker/containers/\(a)/\(a)-json.log")
        #expect(LogFileSizes.path(id: "../../etc") == nil)
    }
}
