import Testing

@testable import ColimaBar

@Suite struct DiskImageSizeTests {
    @Test func candidatesForTheDefaultProfile() {
        #expect(
            DiskImageSize.candidates(limaDir: "/L", profile: "default")
                == ["/L/colima/disk", "/L/colima/diffdisk", "/L/_disks/colima/datadisk"])
    }

    @Test func candidatesForANamedProfile() {
        #expect(
            DiskImageSize.candidates(limaDir: "/L", profile: "work")
                == ["/L/colima-work/disk", "/L/colima-work/diffdisk", "/L/_disks/colima-work/datadisk"])
    }

    @Test func measureSumsAllocatedAndApparentSizes() {
        let files = ["/a": (blocks: Int64(4), size: Int64(1000)), "/b": (blocks: 2, size: 500)]
        let size = DiskImageSize.measure(["/a", "/missing", "/b"]) { files[$0] }
        #expect(size == DiskImageSize(allocated: 6 * 512, apparent: 1500))
    }

    @Test func measureIsNilWhenNoFileExists() {
        #expect(DiskImageSize.measure(["/a", "/b"]) { _ in nil } == nil)
    }
}
