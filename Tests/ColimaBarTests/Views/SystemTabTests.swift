import Foundation
import Testing

@testable import ColimaBar

@Suite @MainActor struct SystemTabTests {
    private let cpu = SystemTab.cpuOpts
    private let mem = SystemTab.memOpts

    @Test func keepsTheVMValueAfterAnotherIsPicked() {
        // Colima's default VM has 2 GB. After you pick 8 GB, 2 GB stays.
        #expect(SystemTab.options(mem, 2, 8) == [2, 4, 8, 12, 16, 24, 32])
        #expect(SystemTab.options(mem, 2, 2) == [2, 4, 8, 12, 16, 24, 32])
    }

    @Test func showsBothOffListValues() {
        #expect(SystemTab.options(cpu, 3, 5) == [2, 3, 4, 5, 6, 8, 10, 12])
        #expect(SystemTab.options(mem, 48, 2) == [2, 4, 8, 12, 16, 24, 32, 48])
    }

    @Test func listedOrUnknownValuesAddNothing() {
        #expect(SystemTab.options(cpu, 4, 8) == cpu)
        #expect(SystemTab.options(cpu, 0, 0) == cpu)  // VM facts not loaded yet
        #expect(SystemTab.options(mem) == mem)
    }
}
