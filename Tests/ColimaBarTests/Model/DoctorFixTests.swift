import Testing

@testable import ColimaBar

@Suite struct DoctorFixTests {
    @Test func eachFixHasAFixedNameForScripts() {
        let names: [(DoctorFix, String)] = [
            (.useColimabar, "useColimabar"), (.setRoutes, "setRoutes"), (.copyLine, "copyLine"),
            (.useOsxkeychain, "useOsxkeychain"), (.addPluginFolder, "addPluginFolder"), (.repair, "repair"),
        ]
        for (fix, name) in names { #expect(fix.id == name) }
    }
}
