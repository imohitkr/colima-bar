import Testing

@testable import ColimaBar

@Suite struct DiskSpaceTests {
    private let gb = DiskSpace.gigabyte

    @Test func parsesTheDataLineOfDf() throws {
        let out = """
            Filesystem     1024-blocks      Used Available Capacity Mounted on
            /dev/vdb1         103080224  51540112  46300000      53% /var/lib/docker
            """
        let u = try #require(DiskSpace.parse(df: out))
        #expect(u == DiskSpace.Usage(usedKB: 51_540_112, availKB: 46_300_000))
        #expect(u.usedPercent == 53)
    }

    @Test func returnsNilForOutputWithoutData() {
        #expect(DiskSpace.parse(df: "") == nil)
        #expect(DiskSpace.parse(df: "df: /var/lib/docker: No such file or directory") == nil)
    }

    private func vm(percent: Int, availGB: Int64) -> DoctorResult.Status {
        let avail = availGB * gb / 1024
        let used = avail * Int64(percent) / Int64(100 - percent)
        return DiskSpace.vm(.init(usedKB: used, availKB: avail)).status
    }

    @Test func theVMDiskIsAProblemAt95PercentOrUnder2GB() {
        #expect(vm(percent: 95, availGB: 20) == .problem)
        #expect(vm(percent: 50, availGB: 1) == .problem)
        #expect(vm(percent: 85, availGB: 20) == .warning)
        #expect(vm(percent: 84, availGB: 20) == .ok)
    }

    @Test func theMacIsAProblemUnder5GBAndAWarningUnder20GB() {
        #expect(DiskSpace.mac(freeBytes: 4 * gb).status == .problem)
        #expect(DiskSpace.mac(freeBytes: 5 * gb).status == .warning)
        #expect(DiskSpace.mac(freeBytes: 19 * gb).status == .warning)
        #expect(DiskSpace.mac(freeBytes: 20 * gb).status == .ok)
    }
}
