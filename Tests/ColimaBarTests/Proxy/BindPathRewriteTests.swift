import Foundation
import Testing

@testable import ColimaBar

@Suite struct BindPathRewriteTests {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    private func object(_ data: Data?) -> NSDictionary? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? NSDictionary }
    }

    private func hostConfig(_ data: Data?) -> [String: Any]? {
        object(data)?["HostConfig"] as? [String: Any]
    }

    @Test func findsCreateRequestsWithAndWithoutVersion() {
        #expect(BindPathRewrite.isContainerCreate("POST /containers/create HTTP/1.1"))
        #expect(BindPathRewrite.isContainerCreate("POST /v1.54/containers/create HTTP/1.1"))
        #expect(BindPathRewrite.isContainerCreate("POST /v1.54/containers/create?name=web HTTP/1.1"))
        #expect(!BindPathRewrite.isContainerCreate("GET /v1.54/containers/create HTTP/1.1"))
        #expect(!BindPathRewrite.isContainerCreate("POST /v1.54/containers/abc/start HTTP/1.1"))
        #expect(!BindPathRewrite.isContainerCreate("POST /v1.54/containers/json HTTP/1.1"))
        #expect(!BindPathRewrite.isContainerCreate("POST /vx/containers/create HTTP/1.1"))
        #expect(!BindPathRewrite.isContainerCreate("POST /containers/create/x HTTP/1.1"))
        #expect(!BindPathRewrite.isContainerCreate(""))
    }

    @Test func rewritesOnlyTheTmpFolder() {
        #expect(BindPathRewrite.rewrittenSource("/tmp") == "/private/tmp")
        #expect(BindPathRewrite.rewrittenSource("/tmp/") == "/private/tmp/")
        #expect(BindPathRewrite.rewrittenSource("/tmp/x/file.py") == "/private/tmp/x/file.py")
        #expect(BindPathRewrite.rewrittenSource("/tmpfoo") == nil)
        #expect(BindPathRewrite.rewrittenSource("/private/tmp/x") == nil)
        #expect(BindPathRewrite.rewrittenSource("/Users/me/tmp") == nil)
        #expect(BindPathRewrite.rewrittenSource("tmp/x") == nil)
        #expect(BindPathRewrite.rewrittenSource("/tmp/../etc") == nil)
    }

    @Test func rewritesOnlyTheSourceOfABind() {
        #expect(BindPathRewrite.rewrittenBind("/tmp/x/file.py:/app/file.py") == "/private/tmp/x/file.py:/app/file.py")
        #expect(BindPathRewrite.rewrittenBind("/tmp/x:/tmp/x:ro,z") == "/private/tmp/x:/tmp/x:ro,z")
        #expect(BindPathRewrite.rewrittenBind("/tmp:/host-tmp") == "/private/tmp:/host-tmp")
        #expect(BindPathRewrite.rewrittenBind("/tmpfoo:/x") == nil)
        #expect(BindPathRewrite.rewrittenBind("/private/tmp/x:/x") == nil)
        #expect(BindPathRewrite.rewrittenBind("cache:/tmp/cache") == nil)
        #expect(BindPathRewrite.rewrittenBind("/Users/me/code:/tmp") == nil)
    }

    @Test func rewritesBinds() throws {
        let body = json(
            #"{"Image":"alpine","HostConfig":{"Binds":["/tmp/x/file.py:/app/file.py","/tmp:/t:ro","/tmpfoo:/f","/private/tmp/y:/y","data:/data"]}}"#
        )
        let binds = try #require(hostConfig(BindPathRewrite.rewrittenBody(body))?["Binds"] as? [String])
        #expect(
            binds == [
                "/private/tmp/x/file.py:/app/file.py", "/private/tmp:/t:ro", "/tmpfoo:/f", "/private/tmp/y:/y",
                "data:/data",
            ])
    }

    @Test func rewritesBindMountsButNotVolumeMounts() throws {
        let body = json(
            #"{"HostConfig":{"Mounts":[{"Type":"bind","Source":"/tmp/a","Target":"/a","ReadOnly":true},{"Type":"volume","Source":"/tmp/b","Target":"/b"},{"Type":"bind","Source":"/Users/me/c","Target":"/c"}]}}"#
        )
        let mounts = try #require(hostConfig(BindPathRewrite.rewrittenBody(body))?["Mounts"] as? [[String: Any]])
        #expect(mounts.map { $0["Source"] as? String } == ["/private/tmp/a", "/tmp/b", "/Users/me/c"])
        #expect(mounts[0]["ReadOnly"] as? Bool == true)
        #expect(mounts[0]["Target"] as? String == "/a")
    }

    @Test func keepsUnknownFields() throws {
        let body = json(
            #"{"Image":"alpine","Env":["A=1"],"Future":{"x":[1,2.5,null,true]},"HostConfig":{"Binds":["/tmp/x:/x"],"Memory":1073741824,"NewField":"kept"}}"#
        )
        let out = try #require(object(BindPathRewrite.rewrittenBody(body)))
        var want = try #require(object(body) as? [String: Any])
        var host = try #require(want["HostConfig"] as? [String: Any])
        host["Binds"] = ["/private/tmp/x:/x"]
        want["HostConfig"] = host
        #expect(out == want as NSDictionary)
    }

    @Test func leavesOtherBodiesAlone() {
        #expect(BindPathRewrite.rewrittenBody(json(#"{"Image":"alpine"}"#)) == nil)
        #expect(BindPathRewrite.rewrittenBody(json(#"{"HostConfig":{"Binds":["/Users/me:/me"]}}"#)) == nil)
        #expect(BindPathRewrite.rewrittenBody(json(#"{"HostConfig":{"Binds":null,"Mounts":null}}"#)) == nil)
        #expect(BindPathRewrite.rewrittenBody(json(#"{"HostConfig":{"Binds":["/tmp/x:/x"]"#)) == nil)
        #expect(BindPathRewrite.rewrittenBody(json(#"["/tmp/x:/x"]"#)) == nil)
        #expect(BindPathRewrite.rewrittenBody(Data()) == nil)
    }

    @Test func setsTheContentLengthAndKeepsTheOtherHeaders() throws {
        let head =
            "POST /v1.54/containers/create HTTP/1.1\r\nHost: api.moby.localhost\r\ncontent-length: 3\r\nX-A: b\r\n\r\n"
        let out = try #require(BindPathRewrite.withContentLength(Data(head.utf8), 120))
        #expect(
            String(decoding: out, as: UTF8.self)
                == "POST /v1.54/containers/create HTTP/1.1\r\nHost: api.moby.localhost\r\nContent-Length: 120\r\nX-A: b\r\n\r\n"
        )
        #expect(BindPathRewrite.withContentLength(Data("POST /x HTTP/1.1\r\nHost: d\r\n\r\n".utf8), 1) == nil)
        let twice = "POST /x HTTP/1.1\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\n"
        #expect(BindPathRewrite.withContentLength(Data(twice.utf8), 1) == nil)
    }

    @Test func rewrittenRequestHasAMatchingContentLength() throws {
        let body = json(#"{"HostConfig":{"Binds":["/tmp/x:/x"]}}"#)
        let head = Data("POST /containers/create HTTP/1.1\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        let out = try #require(BindPathRewrite.rewrittenRequest(head: head, body: body))
        let split = try #require(out.range(of: Data("\r\n\r\n".utf8)))
        let newBody = out[split.upperBound...]
        let length = out[..<split.upperBound].withUnsafeBytes { SocketProxy.bodyLength($0) }
        #expect(length == newBody.count)
        #expect(String(decoding: newBody, as: UTF8.self).contains("/private/tmp/x:/x"))
        #expect(BindPathRewrite.rewrittenRequest(head: head, body: json(#"{"Image":"a"}"#)) == nil)
    }

    @Test func checksThatTheVMSharesPrivateTmp() {
        let home = "/Users/me"
        func shares(_ mounts: [VMMount], defaultHome: Bool = false) -> Bool {
            BindPathRewrite.sharesTarget(mounts: mounts, defaultHome: defaultHome, home: home)
        }
        #expect(shares([VMMount(location: "~"), VMMount(location: "/private/tmp", writable: true)]))
        #expect(shares([VMMount(location: "/private/tmp/")]))
        #expect(shares([VMMount(location: "/private")]))
        #expect(!shares([]))
        #expect(!shares([], defaultHome: true))
        #expect(!shares([VMMount(location: "/private/tmp/x")]))
        #expect(!shares([VMMount(location: "/private/tmp", mountPoint: "/mnt/tmp")]))
    }

    @Test func readsTheColimaYAMLNextToTheSocket() throws {
        let folder = try TempFolder()
        let socket = folder.path + "/docker.sock"
        #expect(!BindPathRewrite.sharesTarget(upstream: socket))
        let yaml =
            "cpu: 2\nmounts:\n  - location: \"~\"\n    writable: true\n  - location: /private/tmp\n    writable: true\n"
        try yaml.write(toFile: folder.path + "/colima.yaml", atomically: true, encoding: .utf8)
        #expect(BindPathRewrite.sharesTarget(upstream: socket))
        try "mounts: []\n".write(toFile: folder.path + "/colima.yaml", atomically: true, encoding: .utf8)
        #expect(!BindPathRewrite.sharesTarget(upstream: socket))
    }
}
