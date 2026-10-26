import Testing

@testable import ColimaBar

@Suite struct ImageRefTests {
    @Test(
        "references are normalized",
        arguments: [
            ("nginx", "docker.io/library/nginx:latest"),
            ("nginx:1.27", "docker.io/library/nginx:1.27"),
            ("bitnami/redis", "docker.io/bitnami/redis:latest"),
            ("docker.io/library/nginx:alpine", "docker.io/library/nginx:alpine"),
            ("index.docker.io/bitnami/redis:7", "docker.io/bitnami/redis:7"),
            ("ghcr.io/owner/app:v1", "ghcr.io/owner/app:v1"),
            ("ghcr.io/owner/app", "ghcr.io/owner/app:latest"),
            ("localhost:5000/app:2", "localhost:5000/app:2"),
            ("localhost/app", "localhost/app:latest"),
            ("registry.local:5000/team/app", "registry.local:5000/team/app:latest"),
            ("quay.io/a/b/c:1", "quay.io/a/b/c:1"),
            ("my_app-1.2:Tag_1", "docker.io/library/my_app-1.2:Tag_1"),
        ])
    func normalizes(input: String, expected: String) {
        #expect(ImageRef.parse(input)?.normalized == expected)
    }

    @Test(
        "references that no tag can follow give nil",
        arguments: [
            "",
            "nginx@sha256:" + String(repeating: "a", count: 64),
            "nginx:1@sha256:" + String(repeating: "a", count: 64),
            "sha256:" + String(repeating: "a", count: 64),
            String(repeating: "a", count: 64),
            "abcdef123456",
            "Nginx",
            "ngi nx",
            "nginx:",
            "nginx:-bad",
            "bad//path",
            "ghcr.io/",
            "host:port/app",
            "app:" + String(repeating: "x", count: 129),
        ])
    func rejects(input: String) {
        #expect(ImageRef.parse(input) == nil)
    }

    @Test func aShortWordIsAnImageNameNotAnID() {
        #expect(ImageRef.parse("cafe")?.normalized == "docker.io/library/cafe:latest")
    }

    @Test func partsAndRepository() throws {
        let ref = try #require(ImageRef.parse("ghcr.io/owner/app:v1"))
        #expect(ref.domain == "ghcr.io" && ref.path == "owner/app" && ref.tag == "v1")
        #expect(ref.repository == "ghcr.io/owner/app")
        #expect(!ref.isDockerHub)
        #expect(ImageRef.parse("redis")?.isDockerHub == true)
    }

    @Test func aDigestEntryGivesItsNormalizedRepository() {
        let digest = "sha256:" + String(repeating: "b", count: 64)
        #expect(ImageRef.repoDigest("nginx@\(digest)")?.repository == "docker.io/library/nginx")
        #expect(ImageRef.repoDigest("nginx@\(digest)")?.digest == digest)
        #expect(ImageRef.repoDigest("ghcr.io/o/a@\(digest)")?.repository == "ghcr.io/o/a")
        #expect(ImageRef.repoDigest("nginx") == nil)
        #expect(ImageRef.repoDigest("nginx@md5:abc") == nil)
    }
}
