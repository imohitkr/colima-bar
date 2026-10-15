import Foundation
import Testing

@testable import ColimaBar

@Suite struct PowerStateTests {
    private func state(_ source: String?, lowPower: Bool = false, thermal: ProcessInfo.ThermalState = .nominal)
        -> PowerState
    {
        PowerState(sourceType: source, lowPowerMode: lowPower, thermal: thermal)
    }

    @Test func batteryAndUPSCountAsOnBattery() {
        #expect(state("Battery Power").onBattery)
        #expect(state("UPS Power").onBattery)
    }

    @Test func theChargerAndAnUnknownSourceCountAsNotOnBattery() {
        #expect(!state("AC Power").onBattery)
        #expect(!state(nil).onBattery)
        #expect(!state("Something else").onBattery)
    }

    @Test func onlySeriousAndCriticalThermalStatesAreHot() {
        #expect(!state(nil, thermal: .nominal).isHot)
        #expect(!state(nil, thermal: .fair).isHot)
        #expect(state(nil, thermal: .serious).isHot)
        #expect(state(nil, thermal: .critical).isHot)
    }

    @Test func lowPowerModeIsCopied() {
        #expect(state("AC Power", lowPower: true).lowPowerMode)
        #expect(!state("AC Power").lowPowerMode)
    }

    @Test func savingFollowsThePowerState() {
        #expect(state("AC Power").saving == .off)
        #expect(state("Battery Power").saving == .battery)
        #expect(state("AC Power", lowPower: true).saving == .strong)
        #expect(state("Battery Power", lowPower: true).saving == .strong)
        #expect(state("AC Power", thermal: .serious).saving == .strong)
        #expect(state("Battery Power", thermal: .critical).saving == .strong)
        #expect(state("Battery Power", thermal: .fair).saving == .battery)
    }
}
