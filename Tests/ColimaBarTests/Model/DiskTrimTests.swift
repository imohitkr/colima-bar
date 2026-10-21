import Testing

@testable import ColimaBar

@Suite struct DiskTrimTests {
    private func size(_ allocated: Int64) -> DiskImageSize { DiskImageSize(allocated: allocated, apparent: 100 << 30) }
    private let gib: Int64 = 1 << 30

    @Test func readsTheTrimmedBytesOfEachFileSystem() {
        let out = """
            /boot/efi: 1.1 GiB (1181116006 bytes) trimmed on /dev/vda15
            /: 1.2 GiB (1288490188 bytes) trimmed on /dev/vda1
            """
        #expect(DiskTrim.trimmedBytes(in: out) == Int64(2_469_606_194))
    }

    @Test func readsTheOlderFormat() {
        #expect(DiskTrim.trimmedBytes(in: "/: 1288490188 bytes were trimmed\n") == 1_288_490_188)
    }

    @Test func noTrimLineGivesNil() {
        #expect(DiskTrim.trimmedBytes(in: "") == nil)
        #expect(DiskTrim.trimmedBytes(in: "fstrim: /: the discard operation is not supported\n") == nil)
    }

    @Test func ignoresNotifyLines() {
        let out = "COLIMABAR_NOTIFY:(5 bytes) trimmed\n/: 7 bytes were trimmed\n"
        #expect(DiskTrim.trimmedBytes(in: out) == 7)
    }

    @Test func aSmallerImageNamesTheSizesBeforeAndAfter() {
        let text = DiskTrim.message(profile: "work", trimmed: gib, before: size(5 * gib), after: size(4 * gib))
        #expect(
            text
                == "Returned free space of profile 'work' to the Mac. The disk image went from 5.0 GB to 4.0 GB.")
    }

    @Test func anImageThatIsNotSmallerSaysSo() {
        let text = DiskTrim.message(profile: "work", trimmed: gib, before: size(5 * gib), after: size(5 * gib))
        #expect(text == "The VM of profile 'work' trimmed 1.0 GB. The disk image on the Mac is still 5.0 GB.")
    }

    @Test func zeroTrimmedSaysThereWasNothingToReturn() {
        let text = DiskTrim.message(profile: "work", trimmed: 0, before: size(gib), after: size(gib))
        #expect(text == "The VM of profile 'work' had no free space to return. The disk image on the Mac is 1.0 GB.")
    }

    @Test func noImageSaysItCouldNotMeasure() {
        let text = DiskTrim.message(profile: "work", trimmed: gib, before: nil, after: nil)
        #expect(
            text == "The VM of profile 'work' trimmed 1.0 GB. ColimaBar could not find the disk image to measure it.")
    }

    @Test func noNumbersAtAllSaysFstrimRan() {
        #expect(
            DiskTrim.message(profile: "work", trimmed: nil, before: nil, after: nil)
                == "The VM of profile 'work' ran fstrim.")
        #expect(
            DiskTrim.message(profile: "work", trimmed: nil, before: size(gib), after: size(gib))
                == "The VM of profile 'work' ran fstrim. The disk image on the Mac is 1.0 GB.")
    }
}
