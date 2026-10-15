import Foundation
import IOKit.ps
import os

/// What the Mac does with its power now. Auto-stop and the heartbeat read it.
/// The rules are pure, so tests can call them. Only `read()` calls the system.
struct PowerState: Equatable, Sendable {
    private static let log = Logger(category: "power")

    /// The Mac runs on a battery (or a UPS), not on the charger.
    var onBattery = false
    /// Low Power Mode is on.
    var lowPowerMode = false
    /// The thermal state is serious or critical.
    var isHot = false

    /// How much the heartbeat saves.
    enum Saving: Equatable, Sendable {
        case off, battery, strong
    }

    init(onBattery: Bool = false, lowPowerMode: Bool = false, isHot: Bool = false) {
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
        self.isHot = isHot
    }

    /// `sourceType` is the answer of `IOPSGetProvidingPowerSourceType`, nil if
    /// the system gives none: then the Mac counts as on the charger.
    init(sourceType: String?, lowPowerMode: Bool, thermal: ProcessInfo.ThermalState) {
        self.init(
            onBattery: sourceType == kIOPMBatteryPowerKey || sourceType == kIOPMUPSPowerKey,
            lowPowerMode: lowPowerMode,
            isHot: thermal == .serious || thermal == .critical)
    }

    /// Low Power Mode and a hot Mac save the most. The battery saves less.
    var saving: Saving {
        if lowPowerMode || isHot { return .strong }
        return onBattery ? .battery : .off
    }

    /// Reads the state from the system.
    static func read() -> PowerState {
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let type = info.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? }
        if type == nil {
            // The Mac counts as on the charger then.
            log.error("the power source type is not available: the Mac counts as on the charger")
        }
        let process = ProcessInfo.processInfo
        return PowerState(sourceType: type, lowPowerMode: process.isLowPowerModeEnabled, thermal: process.thermalState)
    }
}
