import Testing

@testable import ColimaBar

@Suite struct ShellStartupScanTests {
    private func value(_ text: String, _ flavor: ShellStartupScan.Flavor = .zsh) -> String?? {
        ShellStartupScan.scan(text: text, file: "f", flavor: flavor).map(\.value)
    }

    @Test func readsAnExportAndAPlainAssignment() {
        #expect(value("export DOCKER_HOST=unix:///tmp/a.sock") == .some("unix:///tmp/a.sock"))
        #expect(value("DOCKER_HOST=tcp://remote:2375") == .some("tcp://remote:2375"))
        #expect(value("typeset -x DOCKER_HOST=unix:///tmp/b.sock") == .some("unix:///tmp/b.sock"))
        #expect(value("  export   DOCKER_HOST=unix:///tmp/c.sock  # note") == .some("unix:///tmp/c.sock"))
    }

    @Test func removesQuotes() {
        #expect(value("export DOCKER_HOST=\"unix://$HOME/a b.sock\"") == .some("unix://$HOME/a b.sock"))
        #expect(value("export DOCKER_HOST='unix:///tmp/a.sock'") == .some("unix:///tmp/a.sock"))
    }

    @Test func ignoresCommentsAndOtherVariables() {
        #expect(value("# export DOCKER_HOST=unix:///tmp/a.sock") == nil)
        #expect(value("export DOCKER_HOSTNAME=x") == nil)
        #expect(value("export MY_DOCKER_HOST=x") == nil)
        #expect(value("echo DOCKER_HOST=x") == nil)
    }

    @Test func theLastAssignmentWins() {
        let text = "export DOCKER_HOST=unix:///a\nexport PATH=x\nexport DOCKER_HOST=unix:///b\n"
        let found = ShellStartupScan.scan(text: text, file: "f", flavor: .zsh)
        #expect(found == .init(file: "f", line: 3, value: "unix:///b"))
    }

    @Test func anUnsetRemovesTheValue() {
        #expect(value("export DOCKER_HOST=unix:///a\nunset DOCKER_HOST\n") == .some(nil))
    }

    @Test func findsAnAssignmentAfterASemicolon() {
        #expect(value("cd ~; export DOCKER_HOST=unix:///a") == .some("unix:///a"))
    }

    @Test func findsAnAssignmentInsideABlockOrAfterAnOr() {
        #expect(value("if [ -z \"$X\" ]; then export DOCKER_HOST=unix:///a; fi") == .some("unix:///a"))
        #expect(value("if true; then\n\texport DOCKER_HOST=unix:///b\nfi") == .some("unix:///b"))
        #expect(value("for x in 1; do export DOCKER_HOST=unix:///c; done") == .some("unix:///c"))
        #expect(value("[ -S /x ] || export DOCKER_HOST=unix:///d") == .some("unix:///d"))
        #expect(value("if a; then b; else export DOCKER_HOST=unix:///e; fi") == .some("unix:///e"))
        #expect(value("{ export DOCKER_HOST=unix:///f; }") == .some("unix:///f"))
        #expect(value("export\tDOCKER_HOST=unix:///g") == .some("unix:///g"))
        #expect(value("if x; then unset DOCKER_HOST; fi") == .some(nil))
    }

    @Test func readsFishSyntax() {
        #expect(value("set -gx DOCKER_HOST unix:///a", .fish) == .some("unix:///a"))
        #expect(value("set -x DOCKER_HOST \"unix:///a\"", .fish) == .some("unix:///a"))
        #expect(value("set -e DOCKER_HOST", .fish) == .some(nil))
        // Not exported: not part of the environment.
        #expect(value("set DOCKER_HOST unix:///a", .fish) == nil)
        #expect(value("set -g DOCKER_HOST unix:///a", .fish) == nil)
    }

    @Test func aLaterFileWinsOverAnEarlierOne() {
        let files = [(path: "/h/.zshenv", text: "export DOCKER_HOST=unix:///a"), (path: "/h/.zshrc", text: "ls")]
        #expect(ShellStartupScan.lastAssignment(files: files, flavor: .zsh)?.file == "/h/.zshenv")
        let both = files + [(path: "/h/.zlogin", text: "export DOCKER_HOST=unix:///b")]
        #expect(ShellStartupScan.lastAssignment(files: both, flavor: .zsh)?.value == "unix:///b")
    }

    @Test func picksTheFilesOfTheShell() {
        #expect(ShellStartupScan.flavor(shell: "/bin/zsh") == .zsh)
        #expect(ShellStartupScan.flavor(shell: "/opt/homebrew/bin/fish") == .fish)
        #expect(ShellStartupScan.flavor(shell: "/bin/bash") == .bash)
        #expect(ShellStartupScan.flavor(shell: "/bin/tcsh") == .other)
        #expect(
            ShellStartupScan.files(flavor: .zsh, home: "/h", zdotdir: "/z")
                == ["/z/.zshenv", "/z/.zprofile", "/z/.zshrc", "/z/.zlogin"])
        #expect(ShellStartupScan.files(flavor: .zsh, home: "/h", zdotdir: nil).first == "/h/.zshenv")
        #expect(ShellStartupScan.files(flavor: .fish, home: "/h", zdotdir: nil) == ["/h/.config/fish/config.fish"])
        #expect(ShellStartupScan.files(flavor: .bash, home: "/h", zdotdir: nil).contains("/h/.bashrc"))
    }
}
