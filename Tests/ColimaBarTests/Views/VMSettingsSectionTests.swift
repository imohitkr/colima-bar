import Foundation
import Testing

@testable import ColimaBar

@Suite @MainActor struct VMSettingsSectionTests {
    private let cpu = VMSettingsSection.cpuOpts
    private let mem = VMSettingsSection.memOpts

    @Test func keepsTheVMValueAfterAnotherIsPicked() {
        // Colima's default VM has 2 GB. After you pick 8 GB, 2 GB stays.
        #expect(VMSettingsSection.options(mem, 2, 8) == [2, 4, 8, 12, 16, 24, 32])
        #expect(VMSettingsSection.options(mem, 2, 2) == [2, 4, 8, 12, 16, 24, 32])
    }

    @Test func showsBothOffListValues() {
        #expect(VMSettingsSection.options(cpu, 3, 5) == [2, 3, 4, 5, 6, 8, 10, 12])
        #expect(VMSettingsSection.options(mem, 48, 2) == [2, 4, 8, 12, 16, 24, 32, 48])
    }

    @Test func listedOrUnknownValuesAddNothing() {
        #expect(VMSettingsSection.options(cpu, 4, 8) == cpu)
        #expect(VMSettingsSection.options(cpu, 0, 0) == cpu)  // VM facts not loaded yet
        #expect(VMSettingsSection.options(mem) == mem)
    }
}
