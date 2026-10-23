import Foundation
import Testing

@testable import ColimaBar

@MainActor @Suite struct ColimaModelInspectTests {
    @Test func onlyAHexIDIsInspectable() {
        #expect(ColimaModel.isInspectable(id: "0123456789abcdef"))
        #expect(ColimaModel.isInspectable(id: String(repeating: "a", count: 64)))
        #expect(!ColimaModel.isInspectable(id: ""))
        #expect(!ColimaModel.isInspectable(id: String(repeating: "a", count: 65)))
        #expect(!ColimaModel.isInspectable(id: "abc/../x"))
        #expect(!ColimaModel.isInspectable(id: "ABC"))
        #expect(!ColimaModel.isInspectable(id: "web-1"))
    }

    @Test func aStoppedProfileGivesUnavailableForAValidIDAndForABadID() async {
        let model = ColimaModel(profile: "work", readOnly: true)
        #expect(await model.inspect(id: "0123456789abcdef") == .unavailable)
        #expect(await model.inspect(id: "../x") == .unavailable)
        #expect(await model.inspect(id: "") == .unavailable)
    }

    private struct Probe: Decodable {
        let id: String
        enum CodingKeys: String, CodingKey { case id = "Id" }
    }

    /// The reason that the model gives for a decoding error of `json`.
    private func reason(_ json: String) -> String {
        do {
            _ = try JSONDecoder().decode(Probe.self, from: Data(json.utf8))
            return ""
        } catch { return ColimaModel.inspectFailureReason(error) }
    }

    @Test func aDecodingErrorGivesAReasonWithNoValue() {
        #expect(reason(#"{"Id": 5}"#) == "wrong type in the answer")
        #expect(reason(#"{"Other": "hunter2"}"#) == "missing field in the answer")
        #expect(reason(#"{"Id": null}"#) == "missing value in the answer")
        #expect(reason("not json hunter2") == "answer is not JSON")
        #expect(ColimaModel.inspectFailureReason(CocoaError(.fileNoSuchFile)) == "unreadable answer")
    }
}
