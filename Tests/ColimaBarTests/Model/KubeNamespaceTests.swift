import Testing

@testable import ColimaBar

@Suite struct KubeNamespaceTests {
    @Test func acceptsDNSLabels() {
        for name in ["default", "kube-system", "a", "a1", "1a", "x-y-z", String(repeating: "a", count: 63)] {
            #expect(KubeNamespace.isValid(name), "\(name)")
        }
    }

    @Test func rejectsEverythingElse() {
        let tooLong = String(repeating: "a", count: 64)
        for name in ["", "-a", "a-", "A", "a_b", "a.b", "a b", "a/b", "--namespace=x", "é", tooLong] {
            #expect(!KubeNamespace.isValid(name), "\(name)")
        }
    }

    @Test func parsesNamespaceLinesSortedAndUnique() {
        let listing = "namespace/shop\nnamespace/default\nnamespace/Bad\nnode/x\n\nnamespace/default\n"
        #expect(KubeNamespace.parse(listing: listing) == ["default", "shop"])
        #expect(KubeNamespace.parse(listing: "") == [])
    }
}
