import Foundation
import Testing

@testable import ColimaBar

@Suite struct SettingsTransferTests {
    private typealias T = SettingsTransfer

    private let sample: T.Snapshot = [
        .autoStart: .bool(true),
        .autoStop: .bool(true),
        .autoStopMinutes: .int(45),
        .hideIconWhenStopped: .bool(false),
        .notifyOnCrash: .bool(true),
        .keepRemovedLogs: .bool(false),
        .checkUpdates: .bool(true),
        .profile: .string("work"),
        .launchAtLogin: .bool(true),
    ]

    /// A settings file with `settings` as its JSON settings object.
    private func file(_ settings: String, version: String = "1", format: String = "colimabar-settings") -> Data {
        Data(#"{"format": "\#(format)", "version": \#(version), "app": "0.5.0", "settings": \#(settings)}"#.utf8)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Export

    @Test func roundTripKeepsEveryValue() throws {
        let data = try T.encode(sample, appVersion: "0.5.0")
        let (values, skipped) = try T.decode(data)
        #expect(values == sample)
        #expect(skipped.isEmpty)
    }

    @Test func exportHasTheFormatHeader() throws {
        let root = try object(try T.encode(sample, appVersion: "0.5.0"))
        #expect(root["format"] as? String == "colimabar-settings")
        #expect(root["version"] as? Int == 1)
        #expect(root["app"] as? String == "0.5.0")
        let settings = try #require(root["settings"] as? [String: Any])
        #expect(Set(settings.keys) == Set(T.Setting.allCases.map(\.rawValue)))
    }

    @Test func exportIsStable() throws {
        #expect(try T.encode(sample, appVersion: "1") == T.encode(sample, appVersion: "1"))
    }

    /// One-time and internal keys describe this Mac, not the user's choices.
    @Test func internalKeysAreNeverExported() throws {
        let oneTime: Set<String> = [
            "toldIconHidden", "notifiedVersion", "didOfferLoginItem", "didMigrateLoginItem", "revealOnLaunch",
            "apiVersion",
        ]
        let keys = Set(T.Setting.allCases.map(\.rawValue))
        #expect(keys.isDisjoint(with: oneTime))
        let settings = try #require(try object(try T.encode(sample, appVersion: "1"))["settings"] as? [String: Any])
        #expect(Set(settings.keys).isDisjoint(with: oneTime))
    }

    /// Each exported setting except launchAtLogin is a stored Defaults key
    /// with the same name, so the file uses the same names as the app.
    @Test func settingNamesMatchTheStoredKeys() {
        let stored = Set(Defaults.Key.allCases.map(\.rawValue))
        for s in T.Setting.allCases where s != .launchAtLogin {
            #expect(stored.contains(s.rawValue), "\(s.rawValue)")
        }
    }

    @Test func boolsAndNumbersKeepTheirJSONTypes() throws {
        let text = String(decoding: try T.encode(sample, appVersion: "1"), as: UTF8.self)
        #expect(text.contains(#""autoStart" : true"#))
        #expect(text.contains(#""autoStopMinutes" : 45"#))
    }

    // MARK: - Rejected files

    @Test func rejectsBadJSON() {
        #expect(throws: T.Failure.notJSON) { try T.decode(Data("{not json".utf8)) }
        #expect(throws: T.Failure.notJSON) { try T.decode(Data()) }
    }

    @Test func rejectsAnotherFormat() {
        #expect(throws: T.Failure.wrongFormat) { try T.decode(file("{}", format: "other")) }
        #expect(throws: T.Failure.wrongFormat) { try T.decode(Data("[1, 2]".utf8)) }
        #expect(throws: T.Failure.wrongFormat) { try T.decode(Data(#"{"version": 1, "settings": {}}"#.utf8)) }
    }

    @Test func rejectsANewerVersion() {
        #expect(throws: T.Failure.newerVersion(2)) { try T.decode(file("{}", version: "2")) }
        #expect(T.Failure.newerVersion(2).message.contains("Update ColimaBar"))
    }

    @Test func rejectsAMissingOrBadVersion() {
        #expect(throws: T.Failure.badVersion) { try T.decode(file("{}", version: "0")) }
        #expect(throws: T.Failure.badVersion) { try T.decode(file("{}", version: #""1""#)) }
        #expect(throws: T.Failure.badVersion) { try T.decode(file("{}", version: "true")) }
        #expect(throws: T.Failure.badVersion) { try T.decode(file("{}", version: "1.5")) }
        #expect(throws: T.Failure.badVersion) {
            try T.decode(Data(#"{"format": "colimabar-settings", "settings": {}}"#.utf8))
        }
    }

    @Test func rejectsAFileWithoutSettings() {
        #expect(throws: T.Failure.noSettings) { try T.decode(file("[]")) }
        #expect(throws: T.Failure.noSettings) {
            try T.decode(Data(#"{"format": "colimabar-settings", "version": 1}"#.utf8))
        }
    }

    @Test func rejectsALargeFile() {
        let big = Data(repeating: 0x20, count: T.maxBytes + 1)
        #expect(throws: T.Failure.tooLarge) { try T.decode(big) }
    }

    // MARK: - Values

    @Test func skipsOutOfRangeMinutes() throws {
        for bad in ["0", "1441", "-5", "30.5", "true", #""30""#] {
            let (values, skipped) = try T.decode(file(#"{"autoStopMinutes": \#(bad)}"#))
            #expect(values[.autoStopMinutes] == nil, "\(bad)")
            #expect(skipped.count == 1, "\(bad)")
        }
        #expect(try T.decode(file(#"{"autoStopMinutes": 1}"#)).values[.autoStopMinutes] == .int(1))
        #expect(try T.decode(file(#"{"autoStopMinutes": 1440}"#)).values[.autoStopMinutes] == .int(1440))
    }

    @Test func skipsInvalidProfileNames() throws {
        for bad in [#"".hidden""#, #"".""#, #""..""#, #""""#, #""a/b""#, #""a b""#, #""prof;rm""#, "7"] {
            let (values, skipped) = try T.decode(file(#"{"profile": \#(bad)}"#))
            #expect(values[.profile] == nil, "\(bad)")
            #expect(skipped.count == 1, "\(bad)")
        }
        for good in ["default", "work-2", "a.b_c", "X9"] {
            #expect(T.isValidProfileName(good), "\(good)")
        }
    }

    @Test func skipsNonBoolSwitches() throws {
        let (values, skipped) = try T.decode(file(#"{"autoStart": 1, "autoStop": "true", "notifyOnCrash": false}"#))
        #expect(values == [.notifyOnCrash: .bool(false)])
        #expect(skipped.count == 2)
    }

    @Test func ignoresUnknownAndInternalKeys() throws {
        let (values, skipped) = try T.decode(
            file(#"{"futureKey": 3, "toldIconHidden": true, "apiVersion": "1.47", "autoStop": true}"#))
        #expect(values == [.autoStop: .bool(true)])
        #expect(skipped.isEmpty)
    }

    // MARK: - Plan

    @Test func missingKeysChangeNothing() throws {
        let plan = try T.plan(file(#"{"autoStop": false}"#), current: sample, profiles: ["work"])
        #expect(plan.changes == [T.Change(setting: .autoStop, from: .bool(true), to: .bool(false))])
        #expect(plan.skipped.isEmpty)
    }

    @Test func equalValuesAreNotChanges() throws {
        let data = try T.encode(sample, appVersion: "1")
        let plan = try T.plan(data, current: sample, profiles: ["work"])
        #expect(plan.changes.isEmpty)
    }

    @Test func listsChangesInSettingOrder() throws {
        let plan = try T.plan(
            file(#"{"launchAtLogin": false, "autoStopMinutes": 15, "autoStart": false}"#), current: sample,
            profiles: [])
        #expect(plan.changes.map(\.setting) == [.autoStart, .autoStopMinutes, .launchAtLogin])
        #expect(plan.changes[1].text == "Auto-stop time: 45 min → 15 min")
        #expect(plan.changes[0].text == "Auto-start: on → off")
    }

    @Test func skipsAProfileThatDoesNotExist() throws {
        let plan = try T.plan(file(#"{"profile": "other"}"#), current: sample, profiles: ["default", "work"])
        #expect(plan.changes.isEmpty)
        #expect(plan.skipped.count == 1)
        #expect(plan.skipped[0].contains("colima start --profile other"))

        let ok = try T.plan(file(#"{"profile": "default"}"#), current: sample, profiles: ["default", "work"])
        #expect(ok.changes == [T.Change(setting: .profile, from: .string("work"), to: .string("default"))])
    }

    @Test func keepsInvalidValueNotesInThePlan() throws {
        let plan = try T.plan(file(#"{"autoStopMinutes": 9999, "autoStop": false}"#), current: sample, profiles: [])
        #expect(plan.changes.map(\.setting) == [.autoStop])
        #expect(plan.skipped.count == 1)
        #expect(plan.skipped[0].contains("1 to 1440"))
    }
}
