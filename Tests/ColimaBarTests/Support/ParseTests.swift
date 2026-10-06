import Foundation
import Testing

@testable import ColimaBar

@Suite struct ParseTests {
    @Test func yamlTopLevelAndSection() {
        let yaml = """
            cpu: 4
            rosetta: true
            kubernetes:
              # Enable kubernetes.
              enabled: false
              version: v1.30
            network:
              enabled: true
            """
        #expect(Parse.yaml(yaml, key: "cpu") == "4")
        #expect(Parse.yaml(yaml, key: "rosetta") == "true")
        #expect(Parse.yaml(yaml, key: "enabled", section: "kubernetes") == "false")
        #expect(Parse.yaml(yaml, key: "enabled", section: "network") == "true")
        #expect(Parse.yaml(yaml, key: "missing") == nil)
    }
}
