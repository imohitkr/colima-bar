import Darwin
import Foundation
import Testing

@testable import ColimaBar

@Suite struct FileLimitTests {
    @Test func fileLimitRaisesButNeverLowers() {
        var before = rlimit()
        #expect(getrlimit(RLIMIT_NOFILE, &before) == 0)
        let cap = min(before.rlim_max, rlim_t(OPEN_MAX))

        // A lower target leaves the limit alone.
        #expect(FileLimit.raise(to: 1) == before.rlim_cur)

        let target = min(before.rlim_cur + 64, cap)
        let after = FileLimit.raise(to: target)
        var now = rlimit()
        #expect(getrlimit(RLIMIT_NOFILE, &now) == 0)
        #expect(now.rlim_cur == after)
        #expect(after >= before.rlim_cur)
        #expect(after >= target)
        #expect(after <= now.rlim_max)
    }
}
