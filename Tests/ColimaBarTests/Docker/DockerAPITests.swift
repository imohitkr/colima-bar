import Foundation
import Testing

@testable import ColimaBar

@Suite struct DockerAPITests {
    @Test func dechunk() {
        let body = Data("4\r\nWiki\r\n5;ext=1\r\npedia\r\n0\r\n\r\n".utf8)
        #expect(String(decoding: DockerAPI.dechunk(body), as: UTF8.self) == "Wikipedia")
    }

    @Test func parsesStatusAndLowercasedHeaders() {
        let (status, headers) = DockerAPI.parseHead(
            Data("HTTP/1.1 404 Not Found\r\nApi-Version: 1.54\r\nContent-Type: application/json".utf8))
        #expect(status == 404)
        #expect(headers["api-version"] == "1.54")
        #expect(headers["content-type"] == "application/json")
    }
}
