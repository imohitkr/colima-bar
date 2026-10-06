import Foundation
import Testing

@testable import ColimaBar

@Suite struct BoundedConcurrencyTests {
    @Test func runsAtMostEightAtOnceAndCollectsFailures() async {
        let gauge = Gauge()
        let ids = (0..<30).map { "c\($0)" }
        let failed = await ColimaModel.failures(ids, limit: ColimaModel.projectConcurrency) { id in
            await gauge.enter()
            try? await Task.sleep(for: .milliseconds(10))
            await gauge.leave()
            return id.hasSuffix("7") ? id : nil
        }
        #expect(failed.sorted() == ["c17", "c27", "c7"])
        let peak = await gauge.peak
        #expect(peak <= 8 && peak >= 2, "\(peak)")
        #expect(await ColimaModel.failures([String](), limit: 8) { $0 }.isEmpty)
    }
}
