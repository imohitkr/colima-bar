import Foundation
import Testing

@testable import ColimaBar

@MainActor
@Suite struct LinkInboxTests {
    private let clock = TestClock()

    private func inbox(accepts: Bool = true) -> LinkInbox {
        LinkInbox(acceptsLinks: accepts, clock: { [clock] in clock.now })
    }

    /// Collects the links that the handler gets.
    @MainActor private final class Seen {
        var texts: [String] = []
    }

    @Test func linksWaitUntilTheInboxOpensThenComeInOrder() async {
        let box = inbox()
        let seen = Seen()
        box.receive("colimabar://open")
        box.receive("colimabar://doctor")
        #expect(box.pending == ["colimabar://open", "colimabar://doctor"])
        box.open { seen.texts.append($0) }
        #expect(await waitUntil { seen.texts.count == 2 })
        #expect(seen.texts == ["colimabar://open", "colimabar://doctor"])
        #expect(box.pending.isEmpty)
    }

    @Test func linksAfterOpenReachTheHandler() async {
        let box = inbox()
        let seen = Seen()
        box.open { seen.texts.append($0) }
        box.receive("colimabar://open")
        #expect(await waitUntil { seen.texts == ["colimabar://open"] })
    }

    @Test func theSameLinkWithinTwoSecondsIsDropped() {
        let box = inbox()
        box.receive("colimabar://open")
        box.receive("colimabar://open")
        #expect(box.pending == ["colimabar://open"])
        clock.advance(LinkInbox.repeatWindow + 0.1)
        box.receive("colimabar://open")
        #expect(box.pending.count == 2)
    }

    @Test func theFifthLinkIsDropped() {
        let box = inbox()
        for i in 1...5 { box.receive("colimabar://start?profile=p\(i)") }
        #expect(box.pending.count == 4)
        #expect(!box.pending.contains("colimabar://start?profile=p5"))
    }

    @Test func linksAreDroppedWhileAQuestionIsOpen() {
        let box = inbox()
        box.isAsking = true
        box.receive("colimabar://open")
        #expect(box.pending.isEmpty)
        box.isAsking = false
        box.receive("colimabar://open")
        #expect(box.pending.count == 1)
    }

    @Test func aDebugInboxDropsEveryLink() async {
        let box = inbox(accepts: false)
        let seen = Seen()
        box.open { seen.texts.append($0) }
        box.receive("colimabar://open")
        #expect(box.pending.isEmpty)
        #expect(seen.texts.isEmpty)
    }

    @Test func takeAllEmptiesTheInbox() {
        let box = inbox()
        box.receive("colimabar://open")
        box.receive("colimabar://doctor")
        #expect(box.takeAll() == ["colimabar://open", "colimabar://doctor"])
        #expect(box.pending.isEmpty)
        #expect(box.takeAll().isEmpty)
    }

    @Test func aNoticeForTheSameLinkAndKindComesOncePerMinute() {
        let box = inbox()
        #expect(box.allowsNotice(for: "x", kind: "a"))
        #expect(!box.allowsNotice(for: "x", kind: "a"))
        #expect(box.allowsNotice(for: "y", kind: "a"))
        clock.advance(61)
        #expect(box.allowsNotice(for: "x", kind: "a"))
    }

    @Test func theSameLinkWithAnotherKindGetsItsOwnNotice() {
        let box = inbox()
        #expect(box.allowsNotice(for: "x", kind: "busy"))
        #expect(box.allowsNotice(for: "x", kind: "stopped"))
    }

    @Test func allNoticesTogetherAreCappedPerMinute() {
        let box = inbox()
        for n in 0..<LinkInbox.maxNotices { #expect(box.allowsNotice(for: "link\(n)", kind: "k")) }
        #expect(!box.allowsNotice(for: "another", kind: "k"))
        clock.advance(61)
        #expect(box.allowsNotice(for: "another", kind: "k"))
    }

    @Test func linkTextsBecomeURLsAndTheRestIsCounted() {
        let r = LinkInbox.urls(from: ["colimabar://open", "", "colimabar://doctor"])
        #expect(r.urls.map(\.absoluteString) == ["colimabar://open", "colimabar://doctor"])
        #expect(r.dropped == 1)
    }

    // MARK: - Handoff

    private let now = 1_800_000_000.0

    @Test func aFreshHandoffGivesItsLinks() {
        let value = LinkInbox.handoffValue(["colimabar://open", "colimabar://doctor"], now: now)
        #expect(LinkInbox.handoff(value, now: now + 5) == ["colimabar://open", "colimabar://doctor"])
    }

    @Test func anOldHandoffGivesNothing() {
        let value = LinkInbox.handoffValue(["colimabar://open"], now: now)
        #expect(LinkInbox.handoff(value, now: now + 60).isEmpty)
        #expect(LinkInbox.handoff(value, now: now + 3600).isEmpty)
    }

    @Test func aHandoffFromTheFutureGivesNothing() {
        let value = LinkInbox.handoffValue(["colimabar://open"], now: now + 10)
        #expect(LinkInbox.handoff(value, now: now).isEmpty)
    }

    @Test func aHandoffOfTheWrongShapeGivesNothing() {
        #expect(LinkInbox.handoff(nil, now: now).isEmpty)
        #expect(LinkInbox.handoff("text", now: now).isEmpty)
        #expect(LinkInbox.handoff(["at": "x", "links": ["a"]], now: now).isEmpty)
        #expect(LinkInbox.handoff(["at": now, "links": "a"], now: now).isEmpty)
        #expect(LinkInbox.handoff(["at": now, "links": ["colimabar://open", 5]], now: now).isEmpty)
        #expect(LinkInbox.handoff(["links": ["colimabar://open"]], now: now).isEmpty)
    }

    @Test func aHandoffOfMoreThanFourLinksGivesNothing() {
        let links = (1...5).map { "colimabar://start?profile=p\($0)" }
        #expect(LinkInbox.handoff(LinkInbox.handoffValue(links, now: now), now: now).isEmpty)
        #expect(LinkInbox.handoff(LinkInbox.handoffValue(Array(links.prefix(4)), now: now), now: now).count == 4)
    }

    @Test func aLinkOverTheByteLimitIsLeftOutOfAHandoff() {
        let long = "colimabar://start?profile=" + String(repeating: "a", count: 1024)
        let value = LinkInbox.handoffValue(["colimabar://open", long], now: now)
        #expect(LinkInbox.handoff(value, now: now) == ["colimabar://open"])
    }

    @Test func aHandoffThatIsStillThereWithMyStampIsMine() {
        let value = LinkInbox.handoffValue(["colimabar://open"], now: now)
        #expect(LinkInbox.handoffStamp(value) == now)
        #expect(LinkInbox.handoffIsStillMine(value, stamp: now))
    }

    @Test func aHandoffThatIsGoneOrHasAnotherStampIsNotMine() {
        #expect(!LinkInbox.handoffIsStillMine(nil, stamp: now))
        #expect(!LinkInbox.handoffIsStillMine(LinkInbox.handoffValue([], now: now + 1), stamp: now))
        #expect(LinkInbox.handoffStamp("text") == nil)
    }
}
