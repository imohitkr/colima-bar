import Foundation
import Testing

@testable import ColimaBar

@Suite struct ImageScanErrorTests {
    @Test(arguments: [
        (-1, "", ImageScanError.toolMissing),
        (1, "FATAL --skip-db-update cannot be specified on the first run", .noDatabase),
        (1, "failed to download vulnerability DB: dial tcp: lookup x: no such host", .noDatabase),
        (1, "db does not exist", .noDatabase),
        (1, "failed to load: vulnerability database does not exist", .noDatabase),
        (1, "unable to update vulnerability database", .noDatabase),
        (1, "Get https://x: dial tcp 1.2.3.4:443: i/o timeout", .offline),
        (1, "lookup ghcr.io: no such host", .offline),
        (1, "write: no space left on device", .diskFull),
        (1, "context deadline exceeded", .timeout),
        (15, "", .timeout),
    ])
    func sortsTheEndOfAScanner(status: Int32, log: String, expected: ImageScanError) {
        #expect(ImageScanError.classify(status: status, log: log) == expected)
    }

    @Test func aMissingProgramGivesStatus127BecauseShellRunsEnv() {
        let log = "env: trivy: No such file or directory"
        #expect(ImageScanError.classify(status: 127, log: log) == .toolMissing)
    }

    @Test func aStoppedScannerIsATimeoutWhateverItPrints() {
        let log = "FATAL context canceled"
        #expect(ImageScanError.classify(status: 1, log: log, timedOut: true) == .timeout)
        #expect(ImageScanError.classify(status: 1, log: log) == .other(log))
    }

    @Test(arguments: [
        ("the vulnerability database was built 9 days ago (max allowed age is 5 days)", true),
        ("failed to download vulnerability DB: dial tcp: i/o timeout", true),
        ("unable to update vulnerability database", true),
        ("failed to download vulnerability DB: dial tcp: i/o timeout", false),
    ])
    func aScannerWithADatabaseNeedsAnUpdateNotAFirstScan(log: String, hadDatabase: Bool) {
        let error = ImageScanError.classify(status: 1, log: log, hadDatabase: hadDatabase)
        #expect(error == (hadDatabase ? .databaseUpdate : .noDatabase))
        #expect(!ImageScanError.databaseUpdate.message.contains("first scan"))
    }

    @Test func anUnknownFailureShowsTheLastLineCutTo120Characters() {
        let long = String(repeating: "x", count: 200)
        let error = ImageScanError.classify(status: 2, log: "first\n\(long)\n\n")
        #expect(error == .other(String(repeating: "x", count: 120)))
        #expect(ImageScanError.classify(status: 2, log: "") == .other(""))
        #expect(ImageScanError.other("").message == "The scanner failed.")
    }

    @Test func aMissingDigestMeansThePlatformsAreNotOnDisk() {
        let error = ImageScanError.export("content digest sha256:abc: not found")
        #expect(error.message.contains("every platform"))
        #expect(ImageScanError.export("boom") == .exportFailed("boom"))
    }

    @Test func theMessagesAreFixedText() {
        #expect(ImageScanError.lowDisk(needed: 3 << 30).message.hasPrefix("Not enough free disk space"))
        #expect(ImageScanError.noDatabase.message.hasPrefix("Connect to the internet"))
        #expect(ImageScanError.exportFailed("HTTP 500").message == "Docker could not export the image: HTTP 500")
    }
}
