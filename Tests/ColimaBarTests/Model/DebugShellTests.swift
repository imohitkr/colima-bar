import Foundation
import Testing

@testable import ColimaBar

@Suite struct DebugShellTests {
    static let id = String(repeating: "ab12", count: 16)

    @Test func theIDAccepts64LowercaseHexCharacters() {
        #expect(DebugShell.isValidID(Self.id))
        #expect(DebugShell.isValidID(String(repeating: "0", count: 64)))
    }

    @Test(arguments: [
        "", "ab12ab12ab12", "web", "-x", String(repeating: "A", count: 64), String(repeating: "g", count: 64),
        String(repeating: "a", count: 65), String(repeating: "a", count: 63), String(repeating: "a", count: 63) + "\n",
    ])
    func theIDRejectsAnythingElse(value: String) {
        #expect(!DebugShell.isValidID(value))
    }

    @Test(arguments: [
        "busybox", "busybox:1.37", "nicolaka/netshoot:latest", "localhost:5000/a/b",
        "ghcr.io/a/b@sha256:" + String(repeating: "a", count: 64), "9a", "a.b_c-d",
    ])
    func theImageAcceptsNormalNames(value: String) {
        #expect(DebugShell.isValidImage(value))
    }

    @Test(arguments: [
        "", "-v", "--privileged", "a b", "a;b", "$(id)", "a'b", "a\"b", "a\nb", ".a", "/a", "Busybox", "a`b", "a|b",
        String(repeating: "a", count: 256),
    ])
    func theImageRejectsUnsafeNames(value: String) {
        #expect(!DebugShell.isValidImage(value))
    }

    @Test func theImageAccepts255Characters() {
        #expect(DebugShell.isValidImage(String(repeating: "a", count: 255)))
    }

    @Test func anUnsetOrEmptySettingGivesTheDefaultImage() {
        #expect(DebugShell.image(stored: nil) == (DebugShell.defaultImage, false))
        #expect(DebugShell.image(stored: "  ") == (DebugShell.defaultImage, false))
    }

    @Test func aValidSettingIsTrimmedAndUsed() {
        #expect(DebugShell.image(stored: " nicolaka/netshoot \n") == ("nicolaka/netshoot", false))
    }

    @Test func anInvalidSettingGivesTheDefaultImageAndIsFlagged() {
        #expect(DebugShell.image(stored: "--privileged") == (DebugShell.defaultImage, true))
    }

    @Test func theSidecarNameUsesTheFirst12Characters() {
        #expect(DebugShell.sidecarName(id: Self.id) == "colimabar-debug-ab12ab12ab12")
    }

    @Test func theCtlArgumentsAreTheIDAndTheImage() {
        #expect(DebugShell.ctlArgs(id: Self.id, image: "busybox") == [Self.id, "busybox"])
    }

    @Test func theCtlArgumentsAreNilForABadIDOrImage() {
        #expect(DebugShell.ctlArgs(id: "web", image: "busybox") == nil)
        #expect(DebugShell.ctlArgs(id: Self.id, image: "-v") == nil)
    }

    @Test func onlyTheDebugNamesAreSidecars() {
        #expect(DebugShell.isSidecar(name: "colimabar-debug-ab12ab12ab12"))
        #expect(!DebugShell.isSidecar(name: "web"))
        #expect(!DebugShell.isSidecar(name: nil))
        #expect(!DebugShell.isSidecar(name: "colimabar-debug-foo"))
        #expect(!DebugShell.isSidecar(name: "colimabar-debug-ab12ab12ab1"))
        #expect(!DebugShell.isSidecar(name: "colimabar-debug-ab12ab12ab12x"))
        #expect(!DebugShell.isSidecar(name: "colimabar-debug-AB12AB12AB12"))
    }
}
