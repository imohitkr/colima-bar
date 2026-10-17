import Testing

@testable import ColimaBar

@Suite struct DoctorProbeVersionTests {
    private func problem(_ status: Int32, _ out: String = "") -> String? {
        DoctorProbe.versionProblem(Shell.Result(status: status, out: out))
    }

    @Test func aReadableVersionIsNoProblem() {
        #expect(problem(0, "colima version 0.10.3\n") == nil)
    }

    @Test func aMissingToolATimeOutAndAFailureHaveOwnReasons() {
        #expect(problem(-1) == "not found")
        #expect(problem(15) == "timed out")
        #expect(problem(1) == "exit 1")
        #expect(problem(0, "no digits here") == "unknown output")
    }
}
