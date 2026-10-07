import Testing

@testable import ColimaBar

@Suite struct ProfileNameTests {
    @Test func validNamesMatchTheScriptCheck() {
        for name in ["default", "work", "Work_2", "a.b", "x-y", "-a", "work-2", "a.b_c", "X9"] {
            #expect(ProfileName.isValid(name), "\(name)")
        }
        for name in ["", ".", "..", ".hidden", "a/b", "a b", "naïve", "a;b", "prof;rm"] {
            #expect(!ProfileName.isValid(name), "\(name)")
        }
    }

    @Test func newNamesUseLowercaseLettersDigitsAndSingleHyphens() {
        for name in ["work", "a", "k8s-dev", "team-a-1", String(repeating: "a", count: 30)] {
            #expect(ProfileName.problem(newName: name, existing: []) == nil, "\(name)")
        }
        for name in ["", "Work", "a_b", "a.b", "-a", "a-", "a--b", "a b", String(repeating: "a", count: 31)] {
            #expect(ProfileName.problem(newName: name, existing: []) != nil, "\(name)")
        }
    }

    @Test func newNamesOfTheDefaultProfileAreRefused() {
        for name in ["default", "colima", "colima-work"] {
            #expect(ProfileName.problem(newName: name, existing: []) != nil, "\(name)")
        }
    }

    @Test func anExistingNameIsRefusedInAnyCase() {
        #expect(ProfileName.problem(newName: "work", existing: ["Work"]) == "A profile with this name exists.")
        #expect(ProfileName.problem(newName: "work", existing: ["default", "dev"]) == nil)
    }
}
