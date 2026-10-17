import Foundation
import Testing

@testable import ColimaBar

@Suite struct DiagnosticsPartTests {
    @Test func aStoppedVMSkipsTheStatusAndTheEngineWithAReason() {
        let skipped = DiagnosticsPart.planned(state: .stopped).filter { $0.skipped != nil }
        #expect(skipped.map(\.part) == [.colimaStatus, .engine])
        #expect(skipped.allSatisfy { !($0.skipped ?? "").isEmpty })
    }

    @Test func aRunningVMSkipsNothing() {
        #expect(DiagnosticsPart.planned(state: .running).allSatisfy { $0.skipped == nil })
    }

    @Test func thePlanHasEveryPartOnceInFileOrder() {
        #expect(DiagnosticsPart.planned(state: .running).map(\.part) == DiagnosticsPart.allCases)
        #expect(Set(DiagnosticsPart.allCases.map(\.title)).count == DiagnosticsPart.allCases.count)
    }

    @Test func everyPartEndsBeforeTheCapOfTheWholeRun() {
        for part in DiagnosticsPart.allCases {
            #expect(part.deadline < DiagnosticsPart.runLimit, "\(part)")
            if let t = part.timeout { #expect(part.deadline > t) }
        }
    }

    @Test func theLogPartsHaveACap() {
        #expect(DiagnosticsPart.appLog.cap?.lines == 1_500)
        #expect(DiagnosticsPart.ctlLog.cap?.lines == 400)
        #expect(DiagnosticsPart.limaLog.cap?.lines == 300)
        #expect(DiagnosticsPart.tools.cap == nil)
    }

    @Test func eachStateThatIsNotRunningGivesItsOwnSkipReason() {
        let reasons = [VMState.stopped, .unknown, .notInstalled].map { DiagnosticsPart.engine.skipReason(state: $0) }
        #expect(reasons.allSatisfy { $0 != nil })
        #expect(Set(reasons.compactMap { $0 }).count == 3)
        #expect(DiagnosticsPart.engine.skipReason(state: .unknown) != "the VM is not running")
        #expect(DiagnosticsPart.colimaStatus.skipReason(state: .notInstalled)?.contains("not installed") == true)
        #expect(DiagnosticsPart.lima.skipReason(state: .stopped) == nil)
    }
}
