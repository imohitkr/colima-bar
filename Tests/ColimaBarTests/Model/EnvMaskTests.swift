import Foundation
import Testing

@testable import ColimaBar

@Suite struct EnvMaskTests {
    @Test(arguments: [
        "POSTGRES_PASSWORD", "AWS_SECRET_ACCESS_KEY", "GITHUB_TOKEN", "API_KEY", "STRIPE_KEY", "SSH-KEY", "DB_PASS",
        "SENTRY_DSN", "HASH_SALT",
    ])
    func aSecretNameHidesTheValue(key: String) {
        #expect(EnvMask.isSecret(key: key, value: "plain"), "\(key)")
    }

    @Test(arguments: ["PATH", "AUTHOR", "KEYBOARD", "NODE_ENV", "SALTY", "COMPASS", "PASSENGER"])
    func anOrdinaryNameKeepsThePlainValue(key: String) {
        #expect(!EnvMask.isSecret(key: key, value: "plain"), "\(key)")
    }

    @Test func aValueWithACredentialUrlIsSecretWhateverTheKey() {
        #expect(EnvMask.isSecret(key: "DATABASE_URL", value: "postgres://app:hunter2@db:5432/app"))
        #expect(!EnvMask.isSecret(key: "DATABASE_URL", value: "postgres://db:5432/app"))
    }

    @Test func aTokenShapedValueIsSecretWhateverTheKey() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r"
        #expect(EnvMask.isSecret(key: "SESSION", value: jwt))
    }

    @Test func anEntrySplitsAtTheFirstEquals() {
        let list = EnvMask.entries(["A=b=c", "EMPTY=", "NOVALUE", "API_KEY=x"])
        #expect(list[0] == EnvEntry(key: "A", value: "b=c", isSecret: false))
        #expect(list[1] == EnvEntry(key: "EMPTY", value: "", isSecret: false))
        #expect(list[2] == EnvEntry(key: "NOVALUE", value: "", isSecret: false))
        #expect(list[3] == EnvEntry(key: "API_KEY", value: "x", isSecret: true))
    }

    @Test func maskArgsHidesTheValueAfterASecretFlag() {
        #expect(
            EnvMask.maskArgs(["run", "--password", "hunter2", "--port", "80"])
                == ["run", "--password", EnvMask.mask, "--port", "80"])
    }

    @Test func maskArgsHidesTheValueOfAnEqualsForm() {
        #expect(EnvMask.maskArgs(["--token=abc123", "--name=web"]) == ["--token=\(EnvMask.mask)", "--name=web"])
        #expect(EnvMask.maskArgs(["DB_PASSWORD=x"]) == ["DB_PASSWORD=\(EnvMask.mask)"])
    }

    @Test func maskArgsHidesAWordWithASecretShape() {
        #expect(EnvMask.maskArgs(["serve", "postgres://a:b@h/x"]) == ["serve", EnvMask.mask])
    }

    @Test func maskArgsKeepsAFlagWithNoValueAfterIt() {
        #expect(EnvMask.maskArgs(["--password", "--verbose"]) == ["--password", "--verbose"])
        #expect(EnvMask.maskArgs(["--password"]) == ["--password"])
        #expect(EnvMask.maskArgs([]) == [])
    }

    @Test(arguments: [
        ["redis-server", "--requirepass", "s3cret"], ["redis-server", "--masterauth", "s3cret"],
        ["gpg", "--passphrase", "s3cret"], ["tool", "--api-key", "s3cret"],
    ])
    func maskArgsHidesTheValueAfterAFlagWithASecretWord(args: [String]) {
        let out = EnvMask.maskArgs(args)
        #expect(out == [args[0], args[1], EnvMask.mask])
    }

    @Test func maskArgsHidesTheValueOfAnEqualsFormWithASecretWord() {
        #expect(EnvMask.maskArgs(["--requirepass=s3cret"]) == ["--requirepass=\(EnvMask.mask)"])
        #expect(
            EnvMask.maskArgs(["--masterauth=s3cret", "--port=80"]) == ["--masterauth=\(EnvMask.mask)", "--port=80"])
    }

    @Test func maskArgsHidesSecretsInsideOneShellWord() {
        let out = EnvMask.maskArgs(["sh", "-c", "redis-server --requirepass s3cret && run --token=abc123 --port 80"])
        #expect(out[0...1] == ["sh", "-c"])
        #expect(!out[2].contains("s3cret"))
        #expect(!out[2].contains("abc123"))
        #expect(out[2].contains("redis-server --requirepass \(EnvMask.mask)"))
        #expect(out[2].contains("--port 80"))
    }

    @Test func maskArgsHidesAPasswordKeyInsideOneWord() {
        let out = EnvMask.maskArgs(["sh", "-c", "export DB_PASSWORD=hunter2; start"])
        #expect(!out[2].contains("hunter2"))
        #expect(out[2].contains("start"))
    }

    @Test(arguments: [
        ("REDIS_URL", "redis://:pw@redis:6379"), ("DATABASE_URL", "postgres://u:ab/cd@db/app"),
        ("CONNECTION_STRING", "Server=db;User Id=sa;Pass"), ("GPG_PASSPHRASE", "x"),
        ("DB_CONN_STR", "x"), ("MYCONNSTR", "x"), ("OTHER", "Server=db;Password=x"), ("OTHER", "uid=sa;PWD = x"),
    ])
    func aSecretThatTheFirstRulesMissedIsHidden(key: String, value: String) {
        #expect(EnvMask.isSecret(key: key, value: value), "\(key)=\(value)")
    }
}
