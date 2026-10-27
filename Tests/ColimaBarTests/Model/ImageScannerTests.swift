import Foundation
import Testing

@testable import ColimaBar

@Suite struct ImageScannerTests {
    @Test func trivyReadsOnlyTheExportedFile() {
        let args = ImageScanner.trivy.arguments(input: "/c/a.tar", output: "/c/a.json", layout: .docker, offline: false)
        #expect(
            args == [
                "trivy", "image", "--input", "/c/a.tar", "--format", "json", "--output", "/c/a.json", "--scanners",
                "vuln", "--list-all-pkgs=false", "--quiet", "--timeout", "14m", "--cache-backend", "memory",
                "--offline-scan",
            ])
        #expect(!args.contains("--skip-version-check") && !args.contains("--disable-telemetry"))
        #expect(!args.contains("--exit-code"))
        #expect(!args.contains { $0.contains("docker-host") || $0.contains("image-src") })
    }

    @Test func trivyOfflineSkipsTheDatabaseUpdates() {
        let args = ImageScanner.trivy.arguments(input: "/c/a.tar", output: "/c/a.json", layout: .oci, offline: true)
        #expect(args.suffix(2) == ["--skip-db-update", "--skip-java-db-update"])
        let env = ["TRIVY_DISABLE_TELEMETRY": "true", "TRIVY_SKIP_VERSION_CHECK": "true"]
        #expect(ImageScanner.trivy.environment(offline: true) == env)
        #expect(ImageScanner.trivy.environment(offline: false) == env)
    }

    @Test func grypeReadsADockerArchive() {
        let args = ImageScanner.grype.arguments(input: "/c/a.tar", output: "/c/a.json", layout: .docker, offline: false)
        #expect(args == ["grype", "docker-archive:/c/a.tar", "-o", "json", "--file", "/c/a.json", "-q"])
        #expect(ImageScanner.grype.environment(offline: false) == ["GRYPE_CHECK_FOR_APP_UPDATE": "false"])
    }

    @Test func grypeReadsAnOCIArchive() {
        let args = ImageScanner.grype.arguments(input: "/c/a.tar", output: "/c/a.json", layout: .oci, offline: false)
        #expect(args[1] == "oci-archive:/c/a.tar")
    }

    @Test func grypeOfflineStopsTheDatabaseUpdateAndTheAgeCheck() {
        #expect(
            ImageScanner.grype.environment(offline: true)
                == [
                    "GRYPE_CHECK_FOR_APP_UPDATE": "false", "GRYPE_DB_AUTO_UPDATE": "false",
                    "GRYPE_DB_VALIDATE_AGE": "false",
                ])
    }

    @Test func versionsComeFromTheJSONOfEachTool() {
        #expect(ImageScanner.trivy.version(from: #"{"Version":"0.76.1","VulnerabilityDB":{}}"#) == "0.76.1")
        #expect(ImageScanner.grype.version(from: "update available\n" + #"{"version":"0.121.0"}"#) == "0.121.0")
        #expect(ImageScanner.grype.version(from: "not json") == nil)
        #expect(ImageScanner.grype.version(from: #"{"version":""}"#) == nil)
    }

    @Test func trivyDatabaseIsTheMetadataFile() {
        let home = "/Users/x"
        let present: (String) -> Bool = { $0 == "/Users/x/Library/Caches/trivy/db/metadata.json" }
        #expect(ImageScanner.trivy.hasDatabase(env: [:], home: home, children: { _ in [] }, exists: present))
        #expect(!ImageScanner.trivy.hasDatabase(env: [:], home: home, children: { _ in [] }, exists: { _ in false }))
        let custom: (String) -> Bool = { $0 == "/cache/db/metadata.json" }
        #expect(
            ImageScanner.trivy.hasDatabase(
                env: ["TRIVY_CACHE_DIR": "/cache"], home: home, children: { _ in [] }, exists: custom))
    }

    @Test func grypeDatabaseIsASchemaFolderWithTheDatabaseFile() {
        let home = "/Users/x"
        let dir = "/Users/x/Library/Caches/grype/db"
        #expect(
            ImageScanner.grype.hasDatabase(
                env: [:], home: home, children: { $0 == dir ? ["6"] : [] },
                exists: { $0 == "\(dir)/6/vulnerability.db" })
        )
        #expect(
            !ImageScanner.grype.hasDatabase(
                env: [:], home: home, children: { $0 == dir ? ["6"] : [] }, exists: { _ in false }))
        #expect(
            ImageScanner.grype.hasDatabase(
                env: ["GRYPE_DB_CACHE_DIR": "/g"], home: home, children: { $0 == "/g" ? ["5"] : [] },
                exists: { $0 == "/g/5/vulnerability.db" }))
    }

    @Test func eachScannerParsesItsOwnReportOnly() {
        let trivy = Data(#"{"Results":[{"Vulnerabilities":[{"VulnerabilityID":"CVE-1","PkgName":"a"}]}]}"#.utf8)
        #expect(ImageScanner.trivy.parse(trivy)?.count == 1)
        #expect(ImageScanner.grype.parse(Data("[]".utf8)) == nil)
        #expect(ImageScanner.trivy.parse(Data("nope".utf8)) == nil)
    }
}
