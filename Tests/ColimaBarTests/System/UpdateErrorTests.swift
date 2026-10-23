import Foundation
import Testing

@testable import ColimaBar

@Suite struct UpdateErrorTests {
    @Test func aFailedCheckOrSwapSwitchesToTheReleasePage() {
        let failures: [UpdateError] = [
            .sizeMismatch, .digestMismatch, .attestationFailed, .unpackFailed("x"), .signatureInvalid,
            .bundleInvalid("x"), .macOSBlocked, .swapFailed("x"), .rollbackFailed("/x"),
        ]
        for e in failures { #expect(e.usesReleasePageAfter, "\(e)") }
    }

    @Test func aNetworkProblemACancelAMissingCheckAndBusyWorkKeepTheInstallButton() {
        let passing: [UpdateError] = [
            .cancelled, .network("x"), .notEnoughSpace, .blocked("x"), .attestationUnavailable("x"), .other("x"),
            .needsNewerMacOS(minimum: "15.0", current: "14.8"),
        ]
        for e in passing { #expect(!e.usesReleasePageAfter, "\(e)") }
    }

    @Test func everyErrorHasText() {
        #expect(UpdateError.macOSBlocked.message.contains("macOS did not allow"))
        #expect(UpdateError.blocked("A VM action is running").message.contains("A VM action is running"))
        #expect(UpdateError.rollbackFailed("/tmp/old.app").message.contains("/tmp/old.app"))
        #expect(UpdateError.attestationUnavailable("gh is not logged in").message.contains("gh is not logged in"))
        #expect(UpdateError.other("the disk is full").message.contains("the disk is full"))
    }

    @Test func theBlockedTextReadsAsSentences() {
        let why = UpdatePolicy.blocker(UpdatePolicy.Activity(busyLabels: ["Restarting"])) ?? ""
        let text = UpdateError.blocked(why).message
        #expect(text == "ColimaBar waited 2 minutes. A VM action is running (restarting). ColimaBar did not restart.")
        #expect(!text.contains("did not end in time"))
    }

    @Test func aCancelWinsOverAnyOtherError() {
        #expect(UpdateError.ending(UpdateError.digestMismatch, cancelled: true) == .cancelled)
        #expect(UpdateError.ending(UpdateError.attestationUnavailable("x"), cancelled: true) == .cancelled)
        #expect(UpdateError.ending(CancellationError(), cancelled: false) == .cancelled)
    }

    @Test func anErrorOfTheUpdateKeepsItsKind() {
        #expect(UpdateError.ending(UpdateError.digestMismatch, cancelled: false) == .digestMismatch)
    }

    @Test func anotherErrorIsNeitherAReplaceNorAReleasePageFailure() {
        let disk = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let e = UpdateError.ending(disk, cancelled: false)
        guard case .other = e else {
            Issue.record("expected .other, got \(e)")
            return
        }
        #expect(!e.usesReleasePageAfter)
        #expect(!e.message.contains("replace"))
    }
}
