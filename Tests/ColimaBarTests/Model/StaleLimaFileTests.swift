import Testing

@testable import ColimaBar

@Suite struct StaleLimaFileTests {
    private let lima = "/Users/me/.colima/_lima"

    @Test func parsesTheLinesOfTheScript() {
        let out = """
            gone\t\(lima)/colima/ha.pid\t123
            reused\t\(lima)/colima/vz.pid\t456
            invalid\t\(lima)/_networks/user-v2/usernet_user-v2.pid\t
            """
        let files = StaleLimaFile.parse(out, limaDir: lima)
        #expect(files.map(\.reason) == [.gone, .reused, .invalid])
        #expect(files[1].pid == "456")
        #expect(files[0].name(limaDir: lima) == "colima/ha.pid")
    }

    @Test func dropsPathsOutsideLimasFolder() {
        let out = """
            gone\t/Users/me/Documents/notes.pid\t1
            gone\t\(lima)/../../.ssh/key\t1
            gone\t/Users/me/.colima/_lima-other/ha.pid\t1
            gone\t\(lima)/colima/ha.pid\t1
            """
        #expect(StaleLimaFile.parse(out, limaDir: lima).map(\.path) == ["\(lima)/colima/ha.pid"])
    }

    @Test func keepsOnlyTheNamedDaemonPidFileOutsideLimasFolder() {
        let daemon = "/Users/me/.colima/work/daemon/daemon.pid"
        let out = "reused\t\(daemon)\t5\ngone\t/Users/me/.colima/other/daemon/daemon.pid\t6\n"
        #expect(StaleLimaFile.parse(out, limaDir: lima, daemonPidFile: daemon).map(\.path) == [daemon])
        #expect(StaleLimaFile.parse(out, limaDir: lima).isEmpty)
    }

    @Test func countsTheLinesThatItDrops() {
        let out = "gone\t\(lima)/colima/ha.pid\t1\nusage: colima-ctl.sh\n\nbad\t/x\t1\n"
        let scan = StaleLimaFile.scan(out, limaDir: lima)
        #expect(scan.files.count == 1 && scan.dropped == 2)
    }

    @Test func dropsUnknownReasonsAndShortLines() {
        let out = "delete\t\(lima)/colima/ha.pid\t1\ngarbage\n\n"
        #expect(StaleLimaFile.parse(out, limaDir: lima).isEmpty)
    }
}
