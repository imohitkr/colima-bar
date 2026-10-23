import Testing

@testable import ColimaBar

@MainActor @Suite struct VMConfigViewTests {
    @Test func aPathInTheHomeFolderStartsWithATilde() {
        #expect(VMConfigView.abbreviated("/Users/me", home: "/Users/me") == "~")
        #expect(VMConfigView.abbreviated("/Users/me/code", home: "/Users/me") == "~/code")
        #expect(VMConfigView.abbreviated("/Users/me2/code", home: "/Users/me") == "/Users/me2/code")
        #expect(VMConfigView.abbreviated("/Volumes/Data", home: "/Users/me") == "/Volumes/Data")
    }

    @Test func theForwarderPickerAlsoShowsAValueThatTheFileHas() {
        #expect(VMConfigView.forwarders(including: "ssh") == ["ssh", "grpc"])
        #expect(VMConfigView.forwarders(including: "none") == ["ssh", "grpc", "none"])
    }
}
