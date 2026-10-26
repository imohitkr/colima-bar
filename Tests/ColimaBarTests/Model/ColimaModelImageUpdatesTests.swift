import Foundation
import Testing

@testable import ColimaBar

@MainActor @Suite struct ColimaModelImageUpdatesTests {
    private let d1 = "sha256:" + String(repeating: "1", count: 64)
    private let d2 = "sha256:" + String(repeating: "2", count: 64)
    private let nginx = "docker.io/library/nginx:latest"
    private let otherImage = "docker.io/library/redis:7"
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
        /// The number of /distribution requests that may answer, in the order that they arrive.
        var gate: Box<Int>?
        /// The status of the /distribution answers.
        var distributionStatus = 200
        var pull: FakeDaemon.Answer = .init(chunks: [
            Data(#"{"status":"Status: Downloaded newer image for nginx:latest"}"#.utf8 + [0x0A])
        ])
    }

    private func daemon(_ setup: Setup) throws -> FakeDaemon {
        let rows = list(setup.containers)
        let arrivals = Counter()
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
                guard setup.distributionStatus == 200 else {
                    return .init(
                        status: setup.distributionStatus,
                        body: Data(#"{"message":"toomanyrequests: You have reached your pull rate limit"}"#.utf8))
                }
                let json = #"{"Descriptor":{"digest":"\#(setup.registryDigest)"}}"#
                guard let gate = setup.gate else { return ok(json) }
                arrivals.add()
                let mine = arrivals.value
                return .init(chunks: [Data(json.utf8)], gate: { gate.value >= mine })
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
        m.checkImageUpdates()
        m.checkImagesNow()
        #expect(m.claimImageUpdates(now: Date(), force: true) == nil)
        #expect(!m.canCheckImagesNow && !m.canPullImages)
        #expect(await m.pullImages([try #require(ImageRef.parse("nginx"))]) == false)
        m.pullAllImageUpdates()
        m.pullNewImage(containerID: "c1")
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
        m.imageCheckNowAt = Date()
        m.imageUpdateCache.hub = .init(calls: [Date().timeIntervalSince1970], pausedUntil: 1)
        let hub = m.imageUpdateCache.hub
        m.imageUpdateCheck = false
        #expect(m.imageUpdates == ImageUpdateState())
        #expect(m.imageRunAt.isEmpty)
        #expect(m.imageUpdateCache.entries(of: profile).count == 1)
        // The Check Now gap and the Docker Hub budget do not reset: off and on is no way round them.
        #expect(m.imageCheckNowAt != nil && m.imageUpdateCache.hub == hub)
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
        let gate = Box(0)
        let d = try daemon(Setup(registryDigest: d2, gate: gate))
        defer {
            gate.mutate { $0 = 99 }
            d.stop()
        }
        let m = model(d)
        try await scanned(m)
        m.checkImageUpdates()
        #expect(await waitUntil { self.calls(d, "/distribution/") == 1 })
        let task = try #require(m.imageCheckTask)
        m.imageUpdateCheck = false
        gate.mutate { $0 = 99 }
        await task.value
        #expect(calls(d, "/distribution/") == 1)
        #expect(m.imageUpdateCache.entries(of: profile).isEmpty)
        #expect(m.imageUpdates == ImageUpdateState())
        // The calls happened: the budget has them.
        #expect(m.imageUpdateCache.hub.calls.count == 1)
    }

    @Test func theEndOfAnOldRunDoesNotEndTheRunThatReplacedIt() async throws {
        let gate = Box(0)
        let d = try daemon(Setup(registryDigest: d2, gate: gate))
        defer {
            gate.mutate { $0 = 99 }
            d.stop()
        }
        let m = model(d)
        try await scanned(m)
        m.checkImageUpdates()
        #expect(await waitUntil { self.calls(d, "/distribution/") == 1 })
        let first = try #require(m.imageCheckTask)
        // Off and on again: a second run may start while the first still waits.
        m.imageUpdateCheck = false
        m.imageUpdateCheck = true
        await m.refreshImageUpdates()
        #expect(await waitUntil { m.imageUpdates.images[self.nginx] != nil })
        m.checkImageUpdates()
        #expect(await waitUntil { self.calls(d, "/distribution/") == 2 })
        let second = try #require(m.imageCheckTask)
        // The first request answers. The second still waits.
        gate.mutate { $0 = 1 }
        await first.value
        #expect(m.imageChecking && m.imageUpdates.checking)
        gate.mutate { $0 = 99 }
        await second.value
        #expect(!m.imageChecking)
        #expect(m.imageUpdates.containers["c1"] == .update(digest: d2))
    }

    @Test func aSwitchOfTheProfileDuringARunDropsTheResultsButKeepsThePaidAnswer() async throws {
        let gate = Box(0)
        let d = try daemon(Setup(registryDigest: d2, gate: gate))
        defer {
            gate.mutate { $0 = 99 }
            d.stop()
        }
        let m = model(d)
        try await scanned(m)
        m.checkImageUpdates()
        #expect(await waitUntil { self.calls(d, "/distribution/") == 1 })
        let task = try #require(m.imageCheckTask)
        m.dropDataOfOldSocket()
        gate.mutate { $0 = 99 }
        await task.value
        #expect(!m.imageChecking)
        #expect(m.imageUpdates == ImageUpdateState())
        // The answer belongs to the profile that asked, and the registry call cannot be undone.
        #expect(m.imageUpdateCache.entries(of: profile)[nginx]?.digest == d2)
    }

    @Test func aRunThatEndsAfterTheVMStoppedChangesNoEntry() async throws {
        let gate = Box(0)
        let d = try daemon(Setup(registryDigest: d2, gate: gate))
        defer {
            gate.mutate { $0 = 99 }
            d.stop()
        }
        let m = model(d)
        try await scanned(m)
        m.applyImageAnswers(
            [nginx: .init(digest: d2, checkedAt: Date().addingTimeInterval(-25 * 3600), pulled: true)], profile: profile
        )
        m.checkImageUpdates()
        #expect(await waitUntil { self.calls(d, "/distribution/") == 1 })
        let task = try #require(m.imageCheckTask)
        m.setState(.stopped)
        // The daemon went away, so the answer is a failure.
        d.stop()
        await task.value
        let entry = try #require(m.imageUpdateCache.entries(of: profile)[nginx])
        #expect(entry.digest == d2 && entry.pulled == true && entry.error == nil)
    }

    @Test func checkNowWorksOnceInFiveMinutesAndIgnoresTheHourlyGap() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        m.applyImageAnswers([nginx: .init(digest: d1, checkedAt: Date().addingTimeInterval(-7200))], profile: profile)
        m.imageRunAt[profile] = Date()
        #expect(m.canCheckImagesNow)
        m.checkImagesNow()
        #expect(await waitUntil { m.imageUpdates.images[self.nginx]?.isUpdate == true })
        #expect(calls(d, "/distribution/") == 1)
        #expect(!m.canCheckImagesNow)
    }

    @Test func aFailedCheckKeepsTheLastDigestAndThePulledMark() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        let before = Date().addingTimeInterval(-25 * 3600)
        m.applyImageAnswers([nginx: .init(digest: d2, checkedAt: before, pulled: true)], profile: profile)
        m.applyImageAnswers([nginx: .init(error: .unreachable, checkedAt: Date())], profile: profile)
        let entry = try #require(m.imageUpdateCache.entries(of: profile)[nginx])
        #expect(entry.digest == d2 && entry.pulled == true && entry.error == .unreachable)
        #expect(entry.isValid)
        m.applyImageAnswers([nginx: .init(digest: d1, checkedAt: Date())], profile: profile)
        #expect(m.imageUpdateCache.entries(of: profile)[nginx]?.error == nil)
        // An update that the registry showed stays on the row while the registry is down.
        m.applyImageAnswers([nginx: .init(digest: d2, checkedAt: before)], profile: profile)
        m.applyImageAnswers([nginx: .init(error: .rateLimited, checkedAt: Date())], profile: profile)
        m.rebuildImageUpdates()
        #expect(m.imageUpdates.containers["c2"] == .update(digest: d2))
    }

    // MARK: - Docker Hub budget

    @Test func aClaimWritesItsDockerHubCallsIntoTheSavedBudget() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        m.checkImageUpdates()
        // The call counts before the run ends.
        #expect(m.imageUpdateCache.hub.calls.count == 1)
        let task = try #require(m.imageCheckTask)
        await task.value
        #expect(m.imageUpdateCache.hub.calls.count == 1 && m.imageUpdateCache.hub.pausedUntil == nil)
        // The budget is saved with the cache.
        let text = m.domainsStore.string(forKey: Defaults.Key.imageUpdateCache.rawValue)
        #expect(ImageUpdateCache.decode(text).hub == m.imageUpdateCache.hub)
    }

    @Test func aRateLimitedAnswerOfARunPausesDockerHubForAllProfiles() async throws {
        var setup = Setup(registryDigest: d2)
        setup.distributionStatus = 429
        let d = try daemon(setup)
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        m.checkImageUpdates()
        let task = try #require(m.imageCheckTask)
        await task.value
        #expect(m.imageUpdateCache.entries(of: profile)[nginx]?.error == .rateLimited)
        #expect(m.imageUpdateCache.hub.pausedUntil != nil)
        #expect(ImageUpdateSchedule.hubAllowance(m.imageUpdateCache.hub, now: Date()) == 0)
    }

    @Test func aRateLimitedAnswerPausesDockerHubAndATrimDoesNotLiftIt() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        let now = Date()
        m.imageUpdateCache.hub = ImageUpdateSchedule.hubSpent(.init(), calls: 1, rateLimited: true, now: now)
        m.applyImageAnswers([nginx: .init(error: .rateLimited, checkedAt: now)], profile: profile)
        #expect(m.claimImageUpdates(now: now.addingTimeInterval(5 * 3600), force: true) == nil)
        // Nothing uses the other image any more, and the trim removes its entry. The pause stays.
        m.applyImageAnswers([otherImage: .init(error: .rateLimited, checkedAt: now)], profile: profile)
        m.trimImageUpdateCache()
        #expect(m.imageUpdateCache.entries(of: profile)[otherImage] == nil)
        #expect(ImageUpdateSchedule.hubAllowance(m.imageUpdateCache.hub, now: now.addingTimeInterval(3600)) == 0)
        #expect(m.claimImageUpdates(now: now.addingTimeInterval(3600), force: true) == nil)
    }

    @Test func aSpentBudgetHoldsBackDockerHubInEveryProfile() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        let now = Date()
        m.imageUpdateCache.hub = ImageUpdateSchedule.hubSpent(.init(), calls: 3, rateLimited: false, now: now)
        #expect(m.claimImageUpdates(now: now) == nil)
        #expect(m.claimImageUpdates(now: now, force: true) == nil)
        // Another profile reads the same saved budget.
        m.saveImageUpdateCache()
        let other = ColimaModel(
            profile: "other", dockerAPI: DockerAPI(socketPath: d.path), domainsStore: m.domainsStore)
        other.setState(.running)
        other.imageUpdateCheck = true
        try await scanned(other)
        #expect(other.claimImageUpdates(now: now) == nil)
        #expect(m.claimImageUpdates(now: now.addingTimeInterval(3601))?.count == 1)
    }

    /// Three tags of one image: three Docker Hub references.
    private func threeTags() -> Setup {
        var setup = Setup(registryDigest: d2)
        setup.containers = [
            ("c1", "nginx", "sha256:old", "running"),
            ("c2", "nginx:1", "sha256:old", "running"),
            ("c3", "nginx:2", "sha256:old", "running"),
        ]
        return setup
    }

    @Test func aResetAfterAClaimDoesNotGiveTheDockerHubCallsBack() async throws {
        let d = try daemon(threeTags())
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        let now = Date()
        #expect(m.claimImageUpdates(now: now)?.count == 3)
        m.resetImageUpdates()
        m.imageRunAt = [:]
        await m.refreshImageUpdates()
        #expect(await waitUntil { !m.imageUpdates.checkable.isEmpty })
        #expect(m.claimImageUpdates(now: now) == nil)
        #expect(m.claimImageUpdates(now: now, force: true) == nil)
    }

    @Test func turningTheSettingOffAndOnDuringARunMakesNoMoreThanThreeDockerHubCalls() async throws {
        let gate = Box(0)
        var setup = threeTags()
        setup.gate = gate
        let d = try daemon(setup)
        defer {
            gate.mutate { $0 = 99 }
            d.stop()
        }
        let m = model(d)
        try await scanned(m)
        #expect(await waitUntil { m.imageUpdates.checkable.count == 3 })
        m.checkImageUpdates()
        #expect(await waitUntil { self.calls(d, "/distribution/") == ImageUpdateSchedule.concurrency })
        let task = try #require(m.imageCheckTask)
        m.imageUpdateCheck = false
        m.imageUpdateCheck = true
        await m.refreshImageUpdates()
        #expect(await waitUntil { m.imageUpdates.checkable.count == 3 })
        m.imageRunAt = [:]
        m.checkImageUpdates()
        m.checkImagesNow()
        gate.mutate { $0 = 99 }
        await task.value
        #expect(calls(d, "/distribution/") <= ImageUpdateSchedule.hubLimit)
        #expect(m.imageUpdateCache.hub.calls.count == 3)
    }

    @Test func aFreshAnswerOfAnotherProfileIsUsedInsteadOfACall() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        let now = Date()
        m.applyImageAnswers(
            [nginx: .init(digest: d2, checkedAt: now.addingTimeInterval(-3600))], profile: "other-profile")
        #expect(m.claimImageUpdates(now: now) == nil)
        #expect(m.imageUpdateCache.entries(of: profile)[nginx]?.digest == d2)
        #expect(m.imageUpdateCache.entries(of: profile)[nginx]?.pulled == nil)
        #expect(m.imageUpdates.containers["c2"] == .update(digest: d2))
        // An old answer or a failure of the other profile is not used.
        let m2 = model(d)
        try await scanned(m2)
        m2.applyImageAnswers(
            [nginx: .init(digest: d2, checkedAt: now.addingTimeInterval(-25 * 3600))], profile: "other-profile")
        #expect(m2.claimImageUpdates(now: now)?.count == 1)
    }

    // MARK: - Gates

    @Test func checkNowIsOffWithAHintWhileEveryReferenceWasCheckedInTheLastHour() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        #expect(m.canCheckImagesNow && m.checkNowBlockedReason == nil)
        m.applyImageAnswers([nginx: .init(digest: d2, checkedAt: Date().addingTimeInterval(-60))], profile: profile)
        #expect(!m.canCheckImagesNow)
        #expect(m.checkNowBlockedReason == Help.checkImagesNowWaiting)
    }

    @Test func checkNowIsOffWhileTheDockerHubBudgetIsSpent() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        m.applyImageAnswers([nginx: .init(digest: d2, checkedAt: Date().addingTimeInterval(-7200))], profile: profile)
        #expect(m.canCheckImagesNow)
        m.imageUpdateCache.hub = ImageUpdateSchedule.hubSpent(.init(), calls: 3, rateLimited: false, now: Date())
        #expect(!m.canCheckImagesNow && m.checkNowBlockedReason == Help.checkImagesNowWaiting)
    }

    @Test func pullsAndChecksWaitForTheSameStatesAsARun() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        #expect(m.canPullImages && m.canCheckImagesNow)
        m.setTrimming(true)
        #expect(!m.canPullImages && !m.canCheckImagesNow)
        #expect(await m.pullImages([try #require(ImageRef.parse("nginx"))]) == false)
        m.setTrimming(false)
        m.holdAction(profile)
        #expect(!m.canPullImages && !m.canCheckImagesNow)
        m.releaseAction(profile)
        m.setState(.stopped)
        #expect(!m.canPullImages && !m.canCheckImagesNow)
        m.setState(.running)
        #expect(calls(d, "/images/create") == 0)
    }

    @Test func checkNowNeedsAReferenceThatTheRegistryCanAnswerFor() async throws {
        var setup = Setup(registryDigest: d2)
        setup.containers = [("c3", "local/build", "sha256:built", "running")]
        let d = try daemon(setup)
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        #expect(m.imageUpdates.checkable.isEmpty)
        #expect(!m.canCheckImagesNow)
    }

    // MARK: - Debug runs

    @Test func theOldPullActionOfTheImagesTabDoesNothingInADebugRun() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d, debug: true)
        let sent = Box<[String]>([])
        m.notifySink = { text in sent.mutate { $0.append(text) } }
        m.run(.imagePull, "nginx:latest")
        #expect(sent.value == [Help.imageUpdateDebug])
        #expect(m.busy == nil && !m.hasActionInFlight)
    }

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
        // A pull in progress holds the gate, so a second pull does not start.
        #expect(await m.pullImages([try #require(ImageRef.parse("nginx"))]) == false)
        pull.cancel()
        _ = await pull.value
        #expect(m.busyActions(profile) == 0)
    }

    @Test func turningTheSettingOffStopsARunningPullBeforeTheNextImage() async throws {
        let open = Box(false)
        var setup = threeTags()
        setup.pull = .init(
            chunks: [Data(#"{"status":"Status: Downloaded newer image"}"#.utf8 + [0x0A])], gate: { open.value })
        let d = try daemon(setup)
        defer {
            open.mutate { $0 = true }
            d.stop()
        }
        let m = model(d)
        try await scanned(m)
        let refs = try ["nginx", "nginx:1", "nginx:2"].map { try #require(ImageRef.parse($0)) }
        let pull = Task { await m.pullImages(refs) }
        #expect(await waitUntil { self.calls(d, "/images/create") == 1 })
        m.imageUpdateCheck = false
        open.mutate { $0 = true }
        #expect(await pull.value == false)
        #expect(calls(d, "/images/create") == 1)
    }

    @Test func aPullThatEndsAfterAProfileSwitchDoesNotReadTheListAgain() async throws {
        var setup = Setup(registryDigest: d2)
        setup.pull = .init(chunks: [Data(#"{"status":"Pulling"}"#.utf8 + [0x0A])], holdOpen: true)
        let d = try daemon(setup)
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        let reads = calls(d, "GET /containers/json")
        let ref = try #require(ImageRef.parse("nginx"))
        let pull = Task { await m.pullImages([ref]) }
        #expect(await waitUntil { m.busyActions(self.profile) == 1 })
        m.dropDataOfOldSocket()
        pull.cancel()
        #expect(await pull.value == false)
        #expect(calls(d, "GET /containers/json") == reads)
        #expect(m.busyActions(profile) == 0)
    }

    @Test func theRowActionPullsOnlyAContainerWithAnUpdate() async throws {
        let d = try daemon(Setup(registryDigest: d2))
        defer { d.stop() }
        let m = model(d)
        try await scanned(m)
        m.pullNewImage(containerID: "c1")  // a recreate, not an update: it returns before it starts a task
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

    @Test func aRowShowsTheCreatedReferenceInsteadOfAnImageID() {
        let d = FakeDaemon(path: TestSocketPath.unique())
        let m = ColimaModel(profile: profile, readOnly: true, dockerAPI: DockerAPI(socketPath: d.path))
        let moved = Container(
            id: "c1", name: "web", image: "sha256:6baf4358", state: "running", status: "Up", ports: [], project: nil)
        #expect(m.displayImage(of: moved) == "sha256:6baf4358")
        m.imageScan.configImages = ["c1": "alpine:latest"]
        #expect(m.displayImage(of: moved) == "alpine:latest")
        let tagged = Container(
            id: "c1", name: "web", image: "alpine:3.19", state: "running", status: "Up", ports: [], project: nil)
        #expect(m.displayImage(of: tagged) == "alpine:3.19")
    }
}
