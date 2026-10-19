import Foundation
import Testing

@testable import ColimaBar

@Suite struct AppLinkTests {
    private func parse(_ text: String) -> Result<AppLink, AppLink.Failure> { AppLink.parse(text) }
    private func failure(_ text: String) -> AppLink.Failure? {
        if case .failure(let f) = parse(text) { return f }
        return nil
    }

    // MARK: - Routes

    @Test func openAndDoctorParse() {
        #expect(parse("colimabar://open") == .success(.open))
        #expect(parse("colimabar://doctor") == .success(.doctor))
    }

    @Test func vmRoutesParseWithAndWithoutProfile() {
        for action in AppLink.VMAction.allCases {
            #expect(parse("colimabar://\(action.rawValue)") == .success(.vm(action, profile: nil)))
            #expect(parse("colimabar://\(action.rawValue)?profile=work") == .success(.vm(action, profile: "work")))
        }
    }

    @Test func aSingleTrailingSlashIsAccepted() {
        #expect(parse("colimabar://start/") == .success(.vm(.start, profile: nil)))
    }

    @Test func extraPathSegmentsAreMalformed() {
        #expect(failure("colimabar://start/x") == .malformed)
        #expect(failure("colimabar:///start") == .malformed)
        #expect(failure("colimabar:/start") == .malformed)
    }

    @Test func theOpaqueFormWorks() {
        #expect(parse("colimabar:start?profile=w") == .success(.vm(.start, profile: "w")))
        #expect(parse("colimabar:open") == .success(.open))
    }

    @Test func schemeAndRouteIgnoreCaseButTheProfileKeepsIt() {
        #expect(parse("COLIMABAR://START?PROFILE=Work") == .success(.vm(.start, profile: "Work")))
    }

    @Test func unknownRoutesFail() {
        #expect(failure("colimabar://") == .unknownRoute)
        #expect(failure("colimabar://delete") == .unknownRoute)
        #expect(failure("colimabar://st%61rt") == .unknownRoute)
    }

    @Test func anotherSchemeFails() {
        #expect(failure("http://start") == .wrongScheme)
        #expect(failure("") == .wrongScheme)
    }

    @Test func userPortAndFragmentAreMalformed() {
        #expect(failure("colimabar://user@start") == .malformed)
        #expect(failure("colimabar://start:80") == .malformed)
        #expect(failure("colimabar://start#x") == .malformed)
    }

    @Test func theByteLimitIsExact() {
        for prefix in ["colimabar://start?profile=", "colimabar:start?profile="] {
            let pad = { (total: Int) in prefix + String(repeating: "a", count: total - prefix.utf8.count) }
            let atLimit = pad(1024)
            let over = pad(1025)
            #expect(atLimit.utf8.count == 1024)
            #expect(over.utf8.count == 1025)
            #expect(failure(atLimit) != .tooLong)
            #expect(failure(over) == .tooLong)
        }
    }

    @Test func leadingWhitespaceIsRejected() {
        #expect(failure(" colimabar://open") != nil)
        #expect(failure("\ncolimabar://open") != nil)
    }

    // MARK: - Parameters

    @Test func onlyOneProfileParameterIsAllowed() {
        #expect(failure("colimabar://start?profil=a") == .badParameter)
        #expect(failure("colimabar://start?x-success=colimabar://open") == .badParameter)
        #expect(failure("colimabar://start?profile=a&profile=b") == .badParameter)
        #expect(failure("colimabar://start?profile=a&x=b") == .badParameter)
        #expect(failure("colimabar://start?%70rofile=a") == .badParameter)
    }

    @Test func openAndDoctorTakeNoParameter() {
        #expect(failure("colimabar://open?profile=a") == .badParameter)
        #expect(failure("colimabar://doctor?profile=a") == .badParameter)
    }

    @Test func badProfileNamesFail() {
        let bad = [
            "..", "%2E%2E", "%252e%252e", ".x", "a%2Fb", "a%0Ab", "%20", "a+b", "%24%28id%29", ";", "`",
            "w%C3%B6rk", "%D0%B0", "", String(repeating: "a", count: 101),
        ]
        for name in bad {
            #expect(failure("colimabar://start?profile=\(name)") == .badProfile, "\(name)")
        }
        #expect(failure("colimabar://start?profile") == .badProfile)
    }

    @Test func aProfileOfTheByteLimitIsAccepted() {
        let name = String(repeating: "a", count: 100)
        #expect(parse("colimabar://stop?profile=\(name)") == .success(.vm(.stop, profile: name)))
    }

    @Test func aPercentEncodedProfileIsDecodedOnce() {
        #expect(parse("colimabar://stop?profile=%77ork") == .success(.vm(.stop, profile: "work")))
    }

    @Test func noFailureTextHoldsTheInput() {
        let inputs = [
            "colimabar://secret-route", "http://secret-host", "colimabar://start?profile=secret$(id)",
            "colimabar://start?secret=1",
        ]
        for input in inputs {
            guard case .failure(let f) = parse(input) else {
                Issue.record("\(input) parsed")
                continue
            }
            #expect(!AppLinkPolicy.text(for: f).contains("secret"))
            #expect(!f.kind.contains("secret"))
        }
    }

    @Test func theRouteAndProfileReadBack() {
        #expect(AppLink.vm(.restart, profile: "w").route == "restart")
        #expect(AppLink.vm(.restart, profile: "w").profile == "w")
        #expect(AppLink.open.profile == nil)
    }

    @Test func actionsMapToTheScriptActions() {
        #expect(AppLink.VMAction.start.ctl == .start)
        #expect(AppLink.VMAction.stop.ctl == .stop)
        #expect(AppLink.VMAction.restart.ctl == .restart)
    }

    // MARK: - Registration

    @Test func theBuildScriptDeclaresTheScheme() throws {
        let script = try String(contentsOf: ScriptSandbox.repo.appendingPathComponent("build.sh"), encoding: .utf8)
        #expect(script.contains("<key>CFBundleURLSchemes</key><array><string>colimabar</string></array>"))
    }
}
