import Testing

@testable import ColimaBar

@Suite struct VMSettingsCheckTests {
    /// A context with a fake file system: only these folders exist.
    private func context(
        vmType: String = "vz", runtime: String = "docker", address: Bool = false,
        folders: Set<String> = ["/Users/me", "/Users/me/code", "/Volumes/Data", "/Users/me/code/app", "/Users/me/work"]
    ) -> VMSettingsCheck.Context {
        var c = VMSettingsCheck.Context()
        c.current.vmType = vmType
        c.current.runtime = runtime
        c.current.address = address
        c.home = "/Users/me"
        c.isFolder = { folders.contains($0) }
        return c
    }

    private func problems(_ change: VMSettingsChange, _ c: VMSettingsCheck.Context? = nil) -> [String] {
        VMSettingsCheck.problems(change, context: c ?? context())
    }

    // MARK: DNS

    @Test func ipv4AndIPv6ServersPass() {
        #expect(problems(VMSettingsChange(dnsServers: ["1.1.1.1", "2001:4860:4860::8888"])).isEmpty)
        #expect(problems(VMSettingsChange(dnsServers: [])).isEmpty)
    }

    @Test(arguments: ["dns.google", "1.1.1", "1.1.1.256", "1.1.1.1:53", "::g"])
    func aServerThatIsNotAnIPAddressFails(server: String) {
        #expect(problems(VMSettingsChange(dnsServers: [server])) == ["\(server) is not an IP address."])
    }

    @Test func aDuplicateServerFails() {
        #expect(
            problems(VMSettingsChange(dnsServers: ["1.1.1.1", "1.1.1.1"])) == ["1.1.1.1 is in the DNS list twice."])
    }

    @Test func moreThanThreeServersFail() {
        let four = ["1.1.1.1", "8.8.8.8", "9.9.9.9", "8.8.4.4"]
        #expect(problems(VMSettingsChange(dnsServers: four)) == ["Use at most 3 DNS servers."])
        #expect(problems(VMSettingsChange(dnsServers: Array(four.prefix(3)))).isEmpty)
    }

    // MARK: Mounts

    @Test func existingFoldersPass() {
        let mounts = [VMMount(location: "~/work"), VMMount(location: "~/code"), VMMount(location: "/Volumes/Data")]
        #expect(problems(VMSettingsChange(mounts: mounts)).isEmpty)
    }

    @Test func aMissingFolderFails() {
        #expect(
            problems(VMSettingsChange(mounts: [VMMount(location: "~/nothing")]))
                == ["~/nothing is not a folder on this Mac."])
    }

    @Test func aPathThatDoesNotStartWithASlashOrATildeFails() {
        for path in ["code", "./code", "~me/code", ""] {
            #expect(
                problems(VMSettingsChange(mounts: [VMMount(location: path)])) == ["\(path) must start with / or ~/."],
                "\(path)")
        }
    }

    @Test func theRootFolderFails() {
        let r = problems(VMSettingsChange(mounts: [VMMount(location: "/")]), context(folders: ["/"]))
        #expect(r == ["Do not mount the root folder /."])
    }

    @Test func twoPathsForTheSameFolderFail() {
        let mounts = [VMMount(location: "~/code"), VMMount(location: "/Users/me/code/")]
        #expect(problems(VMSettingsChange(mounts: mounts)) == ["/Users/me/code/ is in the list twice."])
    }

    @Test func aFolderInsideAnotherFails() {
        let change = VMSettingsChange(mounts: [VMMount(location: "~"), VMMount(location: "~/code/app")])
        #expect(
            problems(change, context(folders: ["/Users/me", "/Users/me/code/app"]))
                == ["~ and ~/code/app overlap. Colima does not start with overlapping folders."])
        let apart = VMSettingsChange(mounts: [VMMount(location: "~/code"), VMMount(location: "/Volumes/Data")])
        #expect(problems(apart).isEmpty)
    }

    @Test func aMountPointCanOverlapToo() {
        let change = VMSettingsChange(mounts: [
            VMMount(location: "~/a", mountPoint: "/data"), VMMount(location: "~/b", mountPoint: "/data/x"),
        ])
        #expect(problems(change, context(folders: ["/Users/me/a", "/Users/me/b"])).count == 1)
    }

    // MARK: Registries

    @Test func httpAndHTTPSMirrorsPass() {
        let c = VMSettingsChange(registryMirrors: ["https://mirror.example.com", "http://localhost:5000"])
        #expect(problems(c).isEmpty)
    }

    @Test(arguments: ["mirror.example.com", "ftp://mirror.example.com", "https://", "https://a b"])
    func aMirrorThatIsNotAnHTTPURLFails(mirror: String) {
        #expect(problems(VMSettingsChange(registryMirrors: [mirror])) == ["\(mirror) is not an http or https URL."])
    }

    @Test func insecureRegistriesAreHostsHostsWithAPortOrRanges() {
        let ok = ["myregistry.com", "myregistry.com:5000", "host.docker.internal:5000", "10.0.0.0/8", "fd00::/8"]
        #expect(problems(VMSettingsChange(insecureRegistries: ok)).isEmpty)
    }

    @Test(arguments: [
        "https://reg.example.com", "reg.example.com:", "reg.example.com:99999", "a:b:c", "10.0.0.0/33", "-x", "a b",
    ])
    func anInsecureRegistryInAnotherFormFails(registry: String) {
        #expect(!problems(VMSettingsChange(insecureRegistries: [registry])).isEmpty, "\(registry)")
    }

    @Test func aDuplicateRegistryFails() {
        #expect(
            problems(VMSettingsChange(insecureRegistries: ["a:5000", "a:5000"]))
                == ["a:5000 is in the insecure registry list twice."])
    }

    // MARK: Conflicts

    @Test func theAddressNeedsTheVZVMType() {
        #expect(
            problems(VMSettingsChange(address: true), context(vmType: "qemu")) == [
                "A reachable IP address needs the vz VM type."
            ])
        #expect(problems(VMSettingsChange(address: true), context(vmType: "")).isEmpty)
    }

    @Test func anAddressThatIsOnCannotBeTurnedOff() {
        #expect(
            problems(VMSettingsChange(address: false), context(address: true)) == [
                "Colima cannot turn off the address of this VM."
            ])
        #expect(problems(VMSettingsChange(address: true), context(address: true)).isEmpty)
    }

    @Test func registriesNeedTheDockerRuntime() {
        let change = VMSettingsChange(registryMirrors: ["https://m.example.com"])
        #expect(problems(change, context(runtime: "containerd")) == ["Registries need the docker runtime."])
        #expect(problems(change, context(runtime: "")).isEmpty)
        // An empty list needs no runtime.
        #expect(problems(VMSettingsChange(registryMirrors: []), context(runtime: "containerd")).isEmpty)
    }

    @Test func thePortForwarderIsOneOfTheKnownOnes() {
        #expect(problems(VMSettingsChange(portForwarder: "grpc")).isEmpty)
        #expect(problems(VMSettingsChange(portForwarder: "fast")) == ["The port forwarder must be ssh, grpc or none."])
    }

    @Test func anUnsetFieldIsNotChecked() {
        #expect(problems(VMSettingsChange(), context(vmType: "qemu", runtime: "containerd")).isEmpty)
    }

    @Test(arguments: [
        "https://user@mirror.example.com", "https://user:pass@mirror.example.com", "https://mirror.example.com?a=1",
        "https://mirror.example.com/?", "https://mirror.example.com#top",
    ])
    func aMirrorThatDockerdRefusesFails(mirror: String) {
        #expect(
            problems(VMSettingsChange(registryMirrors: [mirror]))
                == ["\(mirror) must have no user name, password, query or fragment."])
    }

    @Test func aMirrorWithAPathPasses() {
        #expect(problems(VMSettingsChange(registryMirrors: ["https://mirror.example.com/v2"])).isEmpty)
    }

    @Test func aMirrorWithAPortAndASlashAtTheEndPasses() {
        #expect(problems(VMSettingsChange(registryMirrors: ["http://mirror.example.com:5000/"])).isEmpty)
    }

    @Test(arguments: ["~/a\nb", "~/a\rb", "~/a\tb", "~/a\u{7}b"])
    func aMountPathWithAControlCharacterFails(path: String) {
        let found = problems(VMSettingsChange(mounts: [VMMount(location: path)]))
        #expect(found == ["Folder names with line breaks or control characters are not supported."])
    }
}
