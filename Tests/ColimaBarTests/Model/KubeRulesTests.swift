import Testing

@testable import ColimaBar

@Suite struct KubeRulesTests {
    @Test func listsOnlyForTheContextOfARunningProfile() {
        #expect(KubeRules.mayListNamespaces(context: "colima", runningProfiles: ["default"]))
        #expect(KubeRules.mayListNamespaces(context: "colima-work", runningProfiles: ["default", "work"]))
    }

    @Test func aStoppedProfileMeansNoCall() {
        #expect(!KubeRules.mayListNamespaces(context: "colima-work", runningProfiles: ["default"]))
        #expect(!KubeRules.mayListNamespaces(context: "colima", runningProfiles: []))
    }

    @Test func otherClustersAreNeverContacted() {
        #expect(!KubeRules.mayListNamespaces(context: "prod", runningProfiles: ["default", "prod"]))
        #expect(!KubeRules.mayListNamespaces(context: "colimabar", runningProfiles: ["default"]))
    }
}
