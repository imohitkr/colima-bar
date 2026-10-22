import Foundation
import Testing

@testable import ColimaBar

@Suite struct RedactorTests {
    let redactor = Redactor(
        home: "/Users/jdoe", userNames: ["jdoe", "Jane Doe"], macNames: ["Janes-MacBook-Pro", "Jane's MacBook Pro"])

    private func gone(_ secret: String, in text: String) {
        let out = redactor.redact(text)
        #expect(!out.contains(secret), "\(out)")
    }

    @Test func removesPrivateKeyBlocks() {
        let text = "a\n-----BEGIN OPENSSH PRIVATE KEY-----\nAAAAB3Nza\nC1rZXk\n-----END OPENSSH PRIVATE KEY-----\nb"
        #expect(redactor.redact(text) == "a\n<private key>\nb")
    }

    @Test func removesTokensOfKnownShapes() {
        let tokens = [
            "ghp_abcdefghijklmnopqrstuvwxyz0123456789", "github_pat_11ABCDEFG0abcdefghijkl_mnopqrstuv",
            "glpat-abcdefghijklmnopqrstu", "dckr_pat_abcdefghijklmnopqrstuvw", "xoxb-1234567890-abcdefghij",
            "sk-abcdefghijklmnopqrstuvwxyz", "npm_abcdefghijklmnopqrstuvwxyz0123", "AKIAIOSFODNN7EXAMPLE",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r",
        ]
        for t in tokens {
            #expect(redactor.redact("value \(t) end") == "value <token> end", "\(t)")
        }
    }

    @Test func keepsTheSchemeOfAnAuthorizationHeader() {
        #expect(
            redactor.redact("Authorization: Bearer abc123def456") == "Authorization: Bearer <redacted>")
        #expect(redactor.redact("authorization: Basic dXNlcjpwYXNz") == "authorization: Basic <redacted>")
    }

    @Test func hidesTheValuesOfSecretKeys() {
        gone("hunter2", in: "DB_PASSWORD=hunter2")
        gone("hunter2", in: "password: hunter2")
        gone("hunter2", in: #"{"api_key": "hunter2"}"#)
        gone("hunter2", in: "run --password hunter2 now")
        gone("hunter2", in: "AWS_SECRET_ACCESS_KEY=hunter2")
        gone("hunter2", in: "https://example.org/x?token=hunter2&y=1")
        #expect(redactor.redact("--password hunter2 up") == "--password <redacted> up")
        #expect(redactor.redact("cpu: 4") == "cpu: 4")
    }

    @Test func hidesUserInfoAndHosts() {
        #expect(redactor.redact("ssh://bob:pw@build.corp.example:22/x") == "ssh://<user>@<host>:22/x")
        #expect(redactor.redact("tcp://build.corp.example:2375") == "tcp://<host>:2375")
        #expect(
            redactor.redact("see https://github.com/imohitkr/colima-bar")
                == "see https://github.com/imohitkr/colima-bar")
        #expect(redactor.redact("https://objects.githubusercontent.com/a") == "https://objects.githubusercontent.com/a")
        #expect(
            redactor.redact("http://localhost:8080 and tcp://host.docker.internal:1")
                == "http://localhost:8080 and tcp://host.docker.internal:1")
        #expect(redactor.redact("bob@build-box") == "bob@<host>")
        #expect(redactor.redact("mail bob@corp.example now") == "mail <email> now")
        #expect(redactor.redact("git@github.com:me/repo.git") == "git@github.com:me/repo.git")
    }

    @Test func showsTheHomeFolderAsTilde() {
        #expect(redactor.redact("/Users/jdoe/.colima/default") == "~/.colima/default")
        #expect(redactor.redact("path '/Users/jdoe' ok") == "path '~' ok")
        #expect(redactor.redact("file:///Users/jdoe/a") == "file://~/a")
    }

    @Test func keepsAFolderThatOnlyStartsWithTheHomeFolder() {
        let me = Redactor(home: "/Users/me")
        #expect(me.redact("/Users/me2/x") == "/Users/<user>/x")
        #expect(me.redact("/Users/me/x") == "~/x")
    }

    @Test func hidesOtherUsersFoldersExceptShared() {
        #expect(redactor.redact("/Users/alice/Library/x") == "/Users/<user>/Library/x")
        #expect(redactor.redact("/Users/Shared/x") == "/Users/Shared/x")
    }

    @Test func hidesTheNamesOfTheMacAndTheUser() {
        #expect(redactor.redact("host Janes-MacBook-Pro.local up") == "host <mac-name>.local up")
        #expect(redactor.redact("computer Jane's MacBook Pro") == "computer <mac-name>")
        #expect(redactor.redact("owner JDoe and jane doe") == "owner <user> and <user>")
        #expect(redactor.redact("jdoed is another word") == "jdoed is another word")
    }

    @Test func keepsShortAndCommonUserNames() {
        let r = Redactor(home: "/Users/x", userNames: ["al", "root", "docker", "Admin"], macNames: [])
        #expect(r.redact("al root docker admin") == "al root docker admin")
    }

    @Test func hidesMacAddressesAndPublicIPs() {
        #expect(redactor.redact("link 02:42:ac:11:00:02 up") == "link <mac> up")
        #expect(redactor.redact("peer 8.8.4.4 and 2606:4700:4700::1111") == "peer <ip> and <ip>")
    }

    @Test func keepsVersionsTimesAndPrivateAddresses() {
        let text =
            "colima 0.10.3 at 02:21:41 on 2025:01:03 from 192.168.5.2 10.0.0.1 172.16.4.4 100.64.0.9 127.0.0.1 169.254.1.1 fe80::1 255.255.255.0"
        #expect(redactor.redact(text) == text)
    }

    @Test func aSecondPassChangesNothing() {
        let text = """
            Authorization: Bearer abcdefgh12345678
            token=hunter2 ssh://bob:pw@build.corp.example mail bob@corp.example bob@box
            /Users/jdoe/a /Users/alice/b Janes-MacBook-Pro jdoe 8.8.8.8 02:42:ac:11:00:02
            ghp_abcdefghijklmnopqrstuvwxyz0123456789 "password": "x"
            """
        let once = redactor.redact(text)
        #expect(redactor.redact(once) == once, "\(once)\n---\n\(redactor.redact(once))")
    }

    @Test func leavesNoSecretInAMixedText() {
        let text = "env: AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI ghp_abcdefghijklmnopqrstuvwxyz0123456789 /Users/jdoe/x"
        let out = redactor.redact(text)
        for secret in ["wJalrXUtnFEMI", "ghp_", "jdoe"] { #expect(!out.contains(secret), "\(out)") }
    }

    @Test func hidesNamesInRequestLinesOfAnOlderLog() {
        #expect(
            redactor.redact("waking Colima for: POST /v1.54/containers/billing-db/start")
                == "waking Colima for: POST /v1.54/containers/{name}/start")
        let image = redactor.redact("waking Colima for: GET /v1.54/images/registry.corp.example:5000/team/app:1/json")
        #expect(image == "waking Colima for: GET /v1.54/images/{name}/json")
        #expect(redactor.redact("GET /v1.54/containers/json") == "GET /v1.54/containers/json")
    }

    @Test func hidesAHomePathThatJSONEscapedItsSlashes() {
        #expect(redactor.redact(#"\/Users\/jdoe\/lib\/a.dylib"#) == #"~\/lib\/a.dylib"#)
        #expect(redactor.redact(#"\/Users\/jd\/lib\/a.dylib"#) == #"\/Users\/<user>\/lib\/a.dylib"#)
        let once = redactor.redact(#"\/Users\/jd\/lib"#)
        #expect(redactor.redact(once) == once)
    }

    @Test func hidesPasswordsInUrlsOfAnyScheme() {
        let socks = redactor.redact("proxy socks5://alice:hunter2@10.0.0.5:1080 on")
        #expect(socks == "proxy socks5://<user>@10.0.0.5:1080 on")
        let pg = redactor.redact("postgres://app:hunter2@db.corp.example/x")
        #expect(pg == "postgres://<user>@<host>/x")
        #expect(!redactor.redact("amqp://u:hunter2@mq.internal:5672").contains("hunter2"))
    }

    @Test func keepsKeysThatOnlyContainTheLettersAuth() {
        for text in [
            "author: Jane", #""authenticated": true"#, "PreferredAuthentications publickey",
            "GSSAPIAuthentication no", "NoHostAuthenticationForLocalhost yes", "authors: a b",
        ] {
            let out = Redactor(home: "/Users/x").redact(text)
            #expect(out == text, "\(out)")
        }
    }

    @Test func hidesTheValuesOfAuthKeys() {
        let r = Redactor(home: "/Users/x")
        for text in [
            #"{"auth": "dXNlcjpwdw=="}"#, #""auths": "abc12345""#, "proxy_auth=hunter2", "auth_token: hunter2",
            "authorization=hunter2", "--auth hunter2",
        ] {
            #expect(!r.redact(text).contains("hunter2") && !r.redact(text).contains("dXNlcjpwdw"), "\(text)")
        }
    }

    @Test func keepsYesNoTrueFalseValuesOfSecretKeys() {
        let r = Redactor(home: "/Users/x")
        #expect(r.redact("password_required: true") == "password_required: true")
        #expect(r.redact(#""token_set": false"#) == #""token_set": false"#)
    }

    @Test func keepsOpensshCipherNames() {
        let text = "ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com and curve25519-sha256@libssh.org"
        #expect(redactor.redact(text) == text)
    }

    @Test func aQuotedOrBracketedUrlKeepsItsClosingCharacter() {
        #expect(redactor.redact(#"see "https://build.corp.example" ok"#) == #"see "https://<host>" ok"#)
        #expect(redactor.redact("(tcp://build.corp.example), x") == "(tcp://<host>), x")
        #expect(redactor.redact("'ssh://build.corp.example'") == "'ssh://<host>'")
        #expect(redactor.redact("<http://build.corp.example>") == "<http://<host>>")
        let once = redactor.redact("see tcp://build.corp.example:1")
        #expect(redactor.redact(once) == once)
    }

    @Test func keepsRealSecretsHiddenInKeyForms() {
        #expect(redactor.redact("auth: abc123") == "auth: <redacted>")
        #expect(redactor.redact(#"{"auths":{"x":{"auth":"dXNlcjpwdw=="}}}"#).contains("dXNlcjpwdw==") == false)
        #expect(redactor.redact("Authorization: Basic dXNlcjpwYXNz").contains("dXNlcjpwYXNz") == false)
        #expect(redactor.redact("https://github.com/a/b file:///opt/x") == "https://github.com/a/b file:///opt/x")
    }

    @Test func requestLineRuleKeepsOrdinaryLines() {
        let text = "GET and POST are methods. PUT /tmp/x done. GET / ok"
        #expect(redactor.redact(text) == text)
    }

    @Test func aBigHostileInputFinishesAndIsStable() {
        let unit =
            "auth auth auth:// a@b.c GET /v1.54/images/" + String(repeating: "a/", count: 40)
            + " token=x https://h:p@x.y \\/Users\\/ 1.2.3.4 \n"
        let big = String(repeating: unit, count: 500_000 / unit.utf8.count)
        let start = ContinuousClock.now
        let once = redactor.redact(big)
        #expect(ContinuousClock.now - start < .seconds(60))
        #expect(
            redactor.redact(String(once.prefix(50_000)))
                == redactor.redact(redactor.redact(String(once.prefix(50_000)))))
    }

    @Test func isSecretKeyAgreesWithTheRedaction() {
        let r = Redactor(home: "/Users/x")
        let secret = ["DB_PASSWORD", "AWS_SECRET_ACCESS_KEY", "GITHUB_TOKEN", "api_key", "proxy_auth", "auth"]
        let plain = ["PATH", "AUTHOR", "KEYBOARD", "NODE_ENV", "authenticated", "PreferredAuthentications"]
        for key in secret {
            #expect(Redactor.isSecretKey(key), "\(key)")
            #expect(r.redact("\(key)=value12345") == "\(key)=<redacted>", "\(key)")
        }
        for key in plain {
            #expect(!Redactor.isSecretKey(key), "\(key)")
            #expect(r.redact("\(key)=value12345") == "\(key)=value12345", "\(key)")
        }
    }

    @Test func isSecretKeyNeedsTheStemInTheWholeKey() {
        #expect(!Redactor.isSecretKey(""))
        #expect(!Redactor.isSecretKey("secret value"))
        #expect(!Redactor.isSecretKey("A=secret"))
    }

    @Test func hasSecretShapeFindsTokensAndUrlsWithPasswords() {
        #expect(Redactor.hasSecretShape("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        #expect(
            Redactor.hasSecretShape("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r"))
        #expect(Redactor.hasSecretShape("postgres://app:hunter2@db:5432/x"))
        #expect(Redactor.hasSecretShape("-----BEGIN RSA PRIVATE KEY-----"))
        #expect(!Redactor.hasSecretShape("postgres://db:5432/x"))
        #expect(!Redactor.hasSecretShape("hello"))
    }

    @Test func hasSecretShapeFindsAnEmptyUserASlashInThePasswordAndAPasswordPair() {
        #expect(Redactor.hasSecretShape("redis://:pw@redis:6379"))
        #expect(Redactor.hasSecretShape("postgres://u:ab/cd@db/app"))
        #expect(Redactor.hasSecretShape("Server=db;User Id=sa;Password=x"))
        #expect(Redactor.hasSecretShape("host=db pwd = x"))
        #expect(!Redactor.hasSecretShape("redis://redis:6379"))
        #expect(!Redactor.hasSecretShape("passwords are hidden"))
    }

    @Test func diagnosticsHideAUrlPasswordWithAnEmptyUserOrASlash() {
        gone("pw123", in: "REDIS_URL=redis://:pw123@redis:6379")
        gone("ab/cd", in: "url postgres://u:ab/cd@db/app")
        gone("ab/cd", in: "url postgres://u:ab/cd@db.example.org/app")
        #expect(redactor.redact("redis://:pw123@redis:6379").contains("redis://"))
    }

    @Test func aPassphraseAndAConnectionStringAreSecretKeys() {
        for key in ["GPG_PASSPHRASE", "CONNECTION_STRING", "DB_CONN_STR", "ConnStr"] {
            #expect(Redactor.isSecretKey(key), "\(key)")
            #expect(redactor.redact("\(key)=value12345") == "\(key)=<redacted>", "\(key)")
        }
    }

    @Test func hideSecretValuesKeepsTheRestOfTheText() {
        #expect(
            Redactor.hideSecretValues(in: "run --token abc --name web", with: "XX") == "run --token XX --name web")
        #expect(Redactor.hideSecretValues(in: "a DB_PASSWORD=x b", with: "XX") == "a DB_PASSWORD=XX b")
    }

    @Test func normalDiagnosticsLinesStayUnchanged() {
        let lines = [
            "colima version 0.9.1",
            "Docker version 27.3.1, build ce12230",
            "default  Running  aarch64  4  8GiB  100GiB  docker  192.168.5.2",
            "desktop-linux  moby  Docker Desktop  unix:///Users/x/.docker/run/docker.sock",
            "colima *  moby  colima  unix:///Users/x/.colima/default/docker.sock",
            "origin  https://github.com/abiosoft/colima.git (fetch)",
            "http://localhost:8080/path/x and https://github.com:443/a/b",
            "tcp://127.0.0.1:2375/v1.43/info",
            "Doctor: ok: socket answers on unix:///var/run/docker.sock",
        ]
        for line in lines {
            #expect(
                redactor.redact(line).replacingOccurrences(of: "/Users/<user>", with: "/Users/x") == line, "\(line)")
        }
    }

    @Test func aPortAndPathIsNotAPassword() {
        #expect(!Redactor.hasSecretShape("http://localhost:8080/path/x@v1"))
        #expect(Redactor.hasSecretShape("redis://:1234@redis"))
    }

    @Test func longLinesRedactQuickly() {
        let line = String(repeating: "a://b:c/d ", count: 5000) + String(repeating: "x:", count: 20_000)
        let start = ContinuousClock.now
        _ = redactor.redact(line)
        _ = Redactor.hasSecretShape(line)
        #expect(ContinuousClock.now - start < .seconds(20))
    }
}
