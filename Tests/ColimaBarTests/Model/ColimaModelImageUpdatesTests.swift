import Foundation
import Testing

@testable import ColimaBar

@MainActor @Suite struct ColimaModelImageUpdatesTests {
    private let d1 = "sha256:" + String(repeating: "1", count: 64)
    private let d2 = "sha256:" + String(repeating: "2", count: 64)
    private let nginx = "docker.io/library/nginx:latest"
    private let profile = "image-test-profile"

    /// The images of the fake daemon: nginx was pulled, `local/build` was built here.
    private func list(_ rows: [(id: String, image: String, imageID: String, state: String)]) -> String {
        let items = rows.map {
            #"{"Id":"\#($0.id)","Names":["/\#($0.id)"],"Image":"\#($0.image)","ImageID":"\#($0.imageID)","State":"\#($0.state)","Status":"Up"}"#
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    private struct Setup {
        var containers: [(id: String, image: String, imageID: String, state: String)] = [
            ("c1", "nginx", "sha256:old", "running"),
            ("c2", "nginx", "sha256:new", "running"),
            ("c3", "local/build", "sha256:built", "running"),
            ("c4", "nginx", "sha256:old", "exited"),
        ]
        var architecture = "arm64"
        var registryDigest: String
        var gate: Box<Bool>?
        var pull: FakeDaemon.Answer = .init(chunks: [
            Data(#"{"status":"Status: Downloaded newer image for nginx:latest"}"#.utf8 + [0x0A])
        ])
    }

    private func daemon(_ setup: Setup) throws -> FakeDaemon {
        let rows = list(setup.containers)
        let d = FakeDaemon(path: TestSocketPath.unique()) { [d1 = d1] request in
            let line = request.line
            func ok(_ json: String) -> FakeDaemon.Answer { .init(body: Data(json.utf8)) }
            if line.hasPrefix("GET /containers/json") { return ok(rows) }
            if line.hasPrefix("GET /containers/") {
                let id = line.split(separator: "/")[2]
                let image = setup.containers.first { $0.id == id }?.image ?? "nginx"
                return ok(#"{"Id":"\#(id)","Config":{"Image":"\#(image)"},"Image":"x"}"#)
            }
            if line.hasPrefix("GET /images/docker.io/library/nginx") {
                return ok(
                    #"{"Id":"sha256:new","RepoDigests":["nginx@\#(d1)"],"Os":"linux","Architecture":"\#(setup.architecture)"}"#
                )
            }
            if line.hasPrefix("GET /images/") { return ok(#"{"Id":"sha256:built","RepoDigests":[]}"#) }
            if line.hasPrefix("GET /distribution/") {
                if let gate = setup.gate { while !gate.value { usleep(10_000) } }
                return ok(#"{"Descriptor":{"digest":"\#(setup.registryDigest)"}}"#)
            }
            if line.hasPrefix("GET /info") { return ok(#"{"Architecture":"aarch64"}"#) }
            if line.hasPrefix("POST /images/create") { return setup.pull }
            return .init(status: 404)
        }
        try d.start()
        return d
    }

    private func model(_ d: FakeDaemon, debug: Bool = false, on: Bool = true) -> ColimaModel {
        let m = ColimaModel(profile: profile, readOnly: debug, dockerAPI: DockerAPI(socketPath: d.path))
        m.setState(.running)
        m.imageUpdateCheck = on
        return m
    }

    /// Reads the containers, then waits until the scan has built the results.
    private func scanned(_ m: ColimaModel) async throws {
        #expect(await m.refreshContainers())
        #expect(await waitUntil { !m.imageUpdates.images.isEmpty })
    }

    private func calls(_ d: FakeDaemon, _ part: String) -> Int { d.seen.filter { $0.contains(part) }.count }

    // MARK: - Local pass

    @Test func withTheSettingOffNoImageCallIsMade() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d, on: false)
        #expect(await m.refreshContainers())
        await m.refreshImageUpdates()
        #expect(d.seen.allSatisfy { $0.hasPrefix("GET /containers/json") })
        #expect(m.imageUpdates == ImageUpdateState())
    }

    @Test func theLocalPassFindsARecreateWithNoRegistryCall() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        #expect(m.imageUpdates.containers["c1"] == .recreate)
        #expect(m.imageUpdates.containers["c2"] == .current)
        #expect(m.imageUpdates.containers["c3"] == .skipped(.localOnly))
        #expect(m.imageUpdates.containers["c4"] == .recreate)
        let running = try #require(m.container(withID: "c1"))
        let stopped = try #require(m.container(withID: "c4"))
        #expect(m.imageUpdates.badge(for: running) == .recreate)
        #expect(m.imageUpdates.badge(for: stopped) == nil)
        // One read of each container and one of each image, whatever the number of containers.
        #expect(calls(d, "GET /images/docker.io/library/nginx:latest/json") >= 1)
        #expect(calls(d, "/distribution/") == 0 && calls(d, "/images/create") == 0)
    }

    @Test func aContainerIsReadOnceAndNotAtEachRefresh() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        let before = calls(d, "GET /containers/c1/json")
        #expect(before == 1)
        #expect(await m.refreshContainers())
        #expect(await waitUntil { self.calls(d, "GET /images/docker.io/library/nginx") >= 2 })
        #expect(calls(d, "GET /containers/c1/json") == before)
    }

    @Test func turningTheSettingOffClearsTheResultsButKeepsTheCache() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        m.applyImageAnswers([nginx: .init(digest: d2, checkedAt: Date())], profile: profile)
        m.imageRunAt[profile] = Date()
        m.imageUpdateCheck = false
        #expect(m.imageUpdates == ImageUpdateState())
        #expect(m.imageRunAt.isEmpty && m.imageCheckNowAt == nil)
        #expect(m.imageUpdateCache.entries(of: profile).count == 1)
    }

    // MARK: - Registry pass

    @Test func twoContainersOfOneTagCostOneRegistryCall() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        m.checkImageUpdates()
        #expect(await waitUntil { m.imageUpdates.images[self.nginx]?.isUpdate == true })
        #expect(calls(d, "GET /distribution/") == 1)
        #expect(d.seen.contains("GET /distribution/docker.io/library/nginx:latest/json HTTP/1.0"))
        #expect(m.imageUpdates.containers["c1"] == .update(digest: d2))
        #expect(m.imageUpdates.containers["c2"] == .update(digest: d2))
        #expect(m.imageUpdateCache.entries(of: profile)[nginx]?.digest == d2)
        // The saved text brings the badge back after a relaunch.
        let text = m.domainsStore.string(forKey: Defaults.Key.imageUpdateCache.rawValue)
        #expect(ImageUpdateCache.decode(text).entries(of: profile)[nginx]?.digest == d2)
    }

    @Test func aRunStartsAtMostOnceAnHourAndOnlyWhileNothingBlocksIt() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        let now = Date()
        #expect(m.claimImageUpdates(now: now)?.map(\.normalized) == [nginx])
        m.imageChecking = false
        // The reference is fresh only after an answer. The hourly gap holds the next run back.
        #expect(m.claimImageUpdates(now: now.addingTimeInterval(60)) == nil)
        #expect(m.claimImageUpdates(now: now.addingTimeInterval(3601))?.count == 1)
        m.imageChecking = false
        m.setTrimming(true)
        #expect(m.claimImageUpdates(now: now.addingTimeInterval(7200)) == nil)
        m.setTrimming(false)
        m.setState(.stopped)
        #expect(m.claimImageUpdates(now: now.addingTimeInterval(7200)) == nil)
    }

    @Test func aFreshAnswerKeepsTheReferenceOutOfTheNextRun() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        let now = Date()
        m.applyImageAnswers([nginx: .init(digest: d2, checkedAt: now)], profile: profile)
        #expect(m.claimImageUpdates(now: now.addingTimeInterval(7200)) == nil)
        #expect(m.claimImageUpdates(now: now.addingTimeInterval(25 * 3600))?.count == 1)
    }

    @Test func aResultThatArrivesAfterTheSettingWentOffIsDropped() async throws {
        let gate = Box(false)
        let d = try daemon(Setup(registryDigest: d2, gate: gate))
        defer {
            gate.mutate { $0 = true }
            d.stop()
        }
        let m = model(d)
        try await scanned(m)
        m.checkImageUpdates()
        #expect(await waitUntil { m.imageUpdates.checking })
        m.imageUpdateCheck = false
        gate.mutate { $0 = true }
        #expect(await waitUntil { self.calls(d, "/distribution/") == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(m.imageUpdateCache.entries(of: profile).isEmpty)
        #expect(m.imageUpdates == ImageUpdateState())
    }

    @Test func checkNowWorksOnceInFiveMinutesAndIgnoresTheHourlyGap() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        m.applyImageAnswers([nginx: .init(digest: d1, checkedAt: Date())], profile: profile)
        m.imageRunAt[profile] = Date()
        #expect(m.canCheckImagesNow)
        m.checkImagesNow()
        #expect(await waitUntil { m.imageUpdates.images[self.nginx]?.isUpdate == true })
        #expect(calls(d, "/distribution/") == 1)
        #expect(!m.canCheckImagesNow)
    }

    // MARK: - Debug runs

    @Test func aDebugRunMakesNoRegistryCallAndNoPull() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d, debug: true)
        try await scanned(m)
        #expect(m.imageUpdates.containers["c1"] == .recreate)  // local reads are allowed
        m.imageRunAt = [:]
        #expect(m.claimImageUpdates(now: Date()) == nil)
        #expect(m.claimImageUpdates(now: Date(), force: true) == nil)
        m.checkImageUpdates()
        m.checkImagesNow()
        m.pullAllImageUpdates()
        m.pullNewImage(containerID: "c1")
        #expect(await m.pullImages([try #require(ImageRef.parse("nginx"))]) == false)
        #expect(!m.canCheckImagesNow && !m.canPullImages)
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls(d, "/distribution/") == 0 && calls(d, "/images/create") == 0)
        #expect(m.domainsStore.string(forKey: Defaults.Key.imageUpdateCache.rawValue) == nil)
    }

    @Test func aDebugRunDoesNotSaveTheSetting() {
        let d = FakeDaemon(path: TestSocketPath.unique())
        let m = ColimaModel(profile: profile, readOnly: true, dockerAPI: DockerAPI(socketPath: d.path))
        m.imageUpdateCheck = true
        #expect(m.domainsStore.object(forKey: Defaults.Key.imageUpdateCheck.rawValue) == nil)
    }

    @Test func theSettingIsSavedAndReadBack() {
        let d = FakeDaemon(path: TestSocketPath.unique())
        let first = ColimaModel(profile: profile, dockerAPI: DockerAPI(socketPath: d.path))
        #expect(!first.imageUpdateCheck)
        first.imageUpdateCheck = true
        let second = ColimaModel(
            profile: profile, dockerAPI: DockerAPI(socketPath: d.path), domainsStore: first.domainsStore)
        #expect(second.imageUpdateCheck)
    }

    @Test func aFixtureLoadsOnlyInADebugRunAndWritesNoCache() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let json =
            #"{"results":{"nginx:latest":{"digest":"\#(d2)"},"local/build":{"error":"signInNeeded"},"bad ref":{"digest":"\#(d2)"}}}"#
        let normal = model(d, on: false)
        #expect(!normal.loadImageUpdateFixture(Data(json.utf8)))
        #expect(!normal.imageUpdateCheck && normal.imageUpdateCache.profiles.isEmpty)

        let debug = model(d, debug: true, on: false)
        #expect(!debug.loadImageUpdateFixture(Data("not json".utf8)))
        #expect(debug.loadImageUpdateFixture(Data(json.utf8)))
        #expect(await debug.refreshContainers())
        #expect(await waitUntil { debug.imageUpdates.containers["c1"]?.isUpdate == true })
        #expect(debug.imageUpdates.failures == [.signInNeeded: 1])
        #expect(debug.domainsStore.string(forKey: Defaults.Key.imageUpdateCache.rawValue) == nil)
        #expect(calls(d, "/distribution/") == 0)
    }

    // MARK: - Pull

    @Test func aPullOfAnotherArchitectureNamesThePlatformAndMarksTheDigest() async throws {
        var setup = Setup(registryDigest: d2)
        setup.architecture = "amd64"
        let d = try daemon(setup)
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        m.applyImageAnswers([nginx: .init(digest: d2, checkedAt: Date())], profile: profile)
        #expect(await m.pullImages([try #require(ImageRef.parse("nginx"))]))
        let post = try #require(d.seen.first { $0.hasPrefix("POST /images/create") })
        #expect(post.contains("fromImage=docker%2Eio%2Flibrary%2Fnginx&tag=latest&platform=linux%2Famd64"))
        #expect(m.imageUpdateCache.entries(of: profile)[nginx]?.pulled == true)
        // The list is read again after the pull.
        #expect(calls(d, "GET /containers/json") >= 2)
        #expect(m.imageUpdates.pulling.isEmpty && m.busyActions(profile) == 0)
    }

    @Test func aFailedPullSendsOneNotification() async throws {
        var setup = Setup(registryDigest: d2)
        setup.pull = .init(chunks: [
            Data(#"{"errorDetail":{"message":"unauthorized: authentication required"},"error":"x"}"#.utf8 + [0x0A])
        ])
        let d = try daemon(setup)
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        let sent = Box<[String]>([])
        m.notifySink = { text in sent.mutate { $0.append(text) } }
        #expect(await m.pullImages([try #require(ImageRef.parse("nginx"))]) == false)
        #expect(sent.value == ["Pull failed for \(nginx): unauthorized: authentication required"])
    }

    @Test func aPullBlocksAutoStopTheWeeklyCleanupAndTheCheck() async throws {
        var setup = Setup(registryDigest: d2)
        setup.pull = .init(chunks: [Data(#"{"status":"Pulling"}"#.utf8 + [0x0A])], holdOpen: true)
        let d = try daemon(setup)
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        let ref = try #require(ImageRef.parse("nginx"))
        let pull = Task { await m.pullImages([ref]) }
        #expect(await waitUntil { m.busyActions(self.profile) == 1 })
        #expect(m.hasActionInFlight && m.imageUpdates.pulling == [nginx])
        #expect(ColimaModel.blocksAutoStop(busyMarker: nil, actionsInFlight: m.busyActions(profile)))
        #expect(m.claimImageUpdates(now: Date(), force: true) == nil)
        m.scheduledPrune = true
        defer { m.scheduledPrune = false }
        #expect(!m.claimScheduledPrune(now: Date()))
        // The same tag is not pulled twice at the same time.
        #expect(await m.pullImages([try #require(ImageRef.parse("nginx"))]) == false)
        pull.cancel()
        _ = await pull.value
        #expect(m.busyActions(profile) == 0)
    }

    @Test func theRowActionPullsOnlyAContainerWithAnUpdate() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        m.pullNewImage(containerID: "c1")  // a recreate, not an update
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls(d, "/images/create") == 0)
        m.applyImageAnswers([nginx: .init(digest: d2, checkedAt: Date())], profile: profile)
        m.rebuildImageUpdates()
        m.pullNewImage(containerID: "c1")
        #expect(await waitUntil { self.calls(d, "/images/create") == 1 })
    }

    // MARK: - Cache

    @Test func theCacheKeepsOnlyListedProfilesAndUsedImages() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d)
        let entry = ImageUpdateCache.Entry(digest: d2, checkedAt: Date())
        m.applyImageAnswers([nginx: entry, "docker.io/library/redis:7": entry], profile: profile)
        m.applyImageAnswers([nginx: entry], profile: "gone-profile")
        m.pruneImageUpdateCache(keeping: [profile])
        #expect(Set(m.imageUpdateCache.profiles.keys) == [profile])
        try await scanned(m)
        #expect(await waitUntil { m.imageUpdateCache.entries(of: self.profile).keys.sorted() == [self.nginx] })
        m.pruneImageUpdateCache(keeping: [])
        #expect(!m.imageUpdateCache.profiles.isEmpty)
    }

    @Test func aPulledMarkStaysForTheSameDigestAndEndsForANewOne() {
        let d = FakeDaemon(path: TestSocketPath.unique())
        let m = ColimaModel(profile: profile, dockerAPI: DockerAPI(socketPath: d.path))
        let now = Date()
        m.applyImageAnswers([nginx: .init(digest: d2, checkedAt: now, pulled: true)], profile: profile)
        m.applyImageAnswers([nginx: .init(digest: d2, checkedAt: now)], profile: profile)
        #expect(m.imageUpdateCache.entries(of: profile)[nginx]?.pulled == true)
        m.applyImageAnswers([nginx: .init(digest: d1, checkedAt: now)], profile: profile)
        #expect(m.imageUpdateCache.entries(of: profile)[nginx]?.pulled != true)
    }
}
