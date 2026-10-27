import Foundation
import Testing

@testable import ColimaBar

@Suite struct ImageScanRulesTests {
    private func may(
        enabled: Bool = true, scannerFound: Bool = true, isDebug: Bool = false, updateRestarting: Bool = false,
        running: Bool = true, hasDockerSocket: Bool = true, waking: Bool = false, recreating: Bool = false,
        transferring: Bool = false, proxyTransfers: Int = 0, scanning: Bool = false
    ) -> Bool {
        ImageScanRules.mayScan(
            enabled: enabled, scannerFound: scannerFound, isDebug: isDebug, updateRestarting: updateRestarting,
            running: running, hasDockerSocket: hasDockerSocket, waking: waking, recreating: recreating,
            transferring: transferring, proxyTransfers: proxyTransfers, scanning: scanning)
    }

    @Test func aScanMayStartWhenNothingBlocks() { #expect(may()) }

    @Test func eachBlockerStopsTheScan() {
        #expect(!may(enabled: false))
        #expect(!may(scannerFound: false))
        #expect(!may(isDebug: true))
        #expect(!may(updateRestarting: true))
        #expect(!may(running: false))
        #expect(!may(hasDockerSocket: false))
        #expect(!may(waking: true))
        #expect(!may(recreating: true))
        #expect(!may(transferring: true))
        #expect(!may(proxyTransfers: 1))
        #expect(!may(scanning: true))
    }

    @Test func theExportNeedsTheImageSizeTimes2Point4PlusTwoGB() {
        let gib = ByteFormat.bytesPerGiB
        #expect(ImageScanRules.neededSpace(imageSize: 0) == 2 * gib)
        #expect(ImageScanRules.neededSpace(imageSize: 10 * gib) == 24 * gib + 2 * gib)
        #expect(ImageScanRules.hasSpace(free: 26 * gib, imageSize: 10 * gib))
        #expect(!ImageScanRules.hasSpace(free: 26 * gib - 1, imageSize: 10 * gib))
    }

    @Test func theByteCapIsTwiceTheImageSize() {
        #expect(ImageScanRules.byteCap(imageSize: 500) == 1000)
        #expect(ImageScanRules.byteCap(imageSize: -5) == 0)
    }

    @Test func onlyHexIDsPass() {
        let hex = String(repeating: "ab12", count: 16)
        #expect(ImageScanRules.normalizedID("sha256:" + hex) == hex)
        #expect(ImageScanRules.normalizedID(hex) == hex)
        #expect(ImageScanRules.normalizedID("abcdef123456") == "abcdef123456")
        #expect(ImageScanRules.normalizedID("abc") == nil)
        #expect(ImageScanRules.normalizedID("ABCDEF123456") == nil)
        #expect(ImageScanRules.normalizedID("../../etc/passwd") == nil)
        #expect(ImageScanRules.normalizedID(hex + "0") == nil)
        #expect(ImageScanRules.shortID(hex) == String(hex.prefix(12)))
    }
}
