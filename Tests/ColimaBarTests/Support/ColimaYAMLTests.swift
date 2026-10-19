import Foundation
import Testing

@testable import ColimaBar

@Suite struct ColimaYAMLTests {
    private let template = ColimaTemplate.colima0103

    private func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    /// The lines that differ, for two texts with the same number of lines.
    private func changed(_ old: String, _ new: String) -> [String] {
        let a = lines(old), b = lines(new)
        guard a.count == b.count else { return ["line count \(a.count) -> \(b.count)"] }
        return zip(a, b).filter { $0 != $1 }.map(\.1)
    }

    // MARK: reading

    @Test func theTemplateHasTheColimaDefaults() {
        let r = VMSettings.read(template)
        #expect(r.dnsServers.isEmpty && r.mounts.isEmpty && r.registryMirrors.isEmpty)
        #expect(!r.address && !r.mountInotify)
        #expect(r.portForwarder == "ssh")
        #expect(r.vmType == "qemu" && r.mountType == "sshfs" && r.arch == "host" && r.runtime == "docker")
        #expect(r.readOnly.isEmpty)
    }

    @Test func anEmptyChangeLeavesTheTemplateAsItIs() throws {
        #expect(try ColimaYAML.apply(VMSettingsChange(), to: template) == template)
    }

    @Test func aFieldWithTheSameValueIsNotRewritten() throws {
        let text = "network:\n  dns: [ 1.1.1.1 ]  # my dns\n"
        #expect(try ColimaYAML.apply(VMSettingsChange(dnsServers: ["1.1.1.1"]), to: text) == text)
    }

    @Test(arguments: [
        ("dns: [1.1.1.1, 8.8.8.8]", ["1.1.1.1", "8.8.8.8"]),
        ("dns: [ 1.1.1.1 ,\"8.8.8.8\" ]  # two", ["1.1.1.1", "8.8.8.8"]),
        ("dns: []", []),
        ("dns: null", []),
        ("dns: ~", []),
        ("dns:", []),
        ("dns:\n    - 1.1.1.1\n    - 8.8.8.8", ["1.1.1.1", "8.8.8.8"]),
        ("dns:\n  # servers\n  - 1.1.1.1\n\n  - '8.8.8.8' # google", ["1.1.1.1", "8.8.8.8"]),
        ("dns: [\"::1\"]", ["::1"]),
    ])
    func dnsIsReadInEveryForm(body: String, expected: [String]) {
        let r = VMSettings.read("cpu: 2\nnetwork:\n  address: false\n  \(body)\nvmType: vz\n")
        #expect(r.dnsServers == expected, "\(body)")
        #expect(r.isEditable(.dnsServers))
    }

    @Test func aListAtTheIndentOfItsKeyIsRead() {
        let r = VMSettings.read("network:\n  dns:\n  - 1.1.1.1\n  - 8.8.8.8\nvmType: vz\n")
        #expect(r.dnsServers == ["1.1.1.1", "8.8.8.8"])
    }

    @Test func aKeyWithTheSameNameInAnotherSectionIsNotConfused() throws {
        let text = "docker:\n  dns: [9.9.9.9]\nnetwork:\n  dns: []\n"
        #expect(VMSettings.read(text).dnsServers.isEmpty)
        let new = try ColimaYAML.apply(VMSettingsChange(dnsServers: ["1.1.1.1"]), to: text)
        #expect(new == "docker:\n  dns: [9.9.9.9]\nnetwork:\n  dns: [1.1.1.1]\n")
    }

    @Test func mountsAreReadWithTheirMountPoint() throws {
        let text = """
            mounts:
              - location: ~/code
                writable: true
              # a note
              - location: "/Volumes/Data disk"
                mountPoint: /data
            vmType: vz
            """
        let r = VMSettings.read(text)
        #expect(
            r.mounts == [
                VMMount(location: "~/code", writable: true),
                VMMount(location: "/Volumes/Data disk", writable: false, mountPoint: "/data"),
            ])
        #expect(r.isEditable(.mounts))
    }

    @Test(arguments: [
        "network:\n  dns: &servers [1.1.1.1]\n",
        "network:\n  dns: !!seq [1.1.1.1]\n",
        "network:\n  dns: [1.1.1.1,\n    8.8.8.8]\n",
        "network:\n  dns: |\n    1.1.1.1\n",
        "network:\n  dns: {a: b}\n",
        "network:\n  dns:\n    - [1.1.1.1]\n",
        "network:\n  dns:\n    - ip: 1.1.1.1\n",
        "network:\n  dns: [[1.1.1.1]]\n",
    ])
    func anUnsupportedFormMakesTheFieldReadOnly(text: String) throws {
        let r = VMSettings.read(text)
        #expect(!r.isEditable(.dnsServers), "\(text)")
        #expect(r.dnsServers.isEmpty)
        #expect(throws: ColimaYAML.Failure.unsupported("network.dns")) {
            try ColimaYAML.apply(VMSettingsChange(dnsServers: ["1.1.1.1"]), to: text)
        }
    }

    @Test func aMountWithAnotherKeyMakesMountsReadOnly() {
        let r = VMSettings.read("mounts:\n  - location: ~/code\n    sync: true\n")
        #expect(!r.isEditable(.mounts) && r.mounts.isEmpty)
        #expect(r.isEditable(.dnsServers))
    }

    @Test func aMapOfDockerKeysInOneLineMakesTheRegistriesReadOnly() {
        let r = VMSettings.read("docker: {insecure-registries: [a:5000]}\n")
        #expect(!r.isEditable(.registryMirrors) && !r.isEditable(.insecureRegistries))
    }

    // MARK: writing

    @Test func aDNSChangeTouchesOnlyTheDNSLine() throws {
        let new = try ColimaYAML.apply(VMSettingsChange(dnsServers: ["1.1.1.1", "8.8.8.8"]), to: template)
        #expect(changed(template, new) == ["  dns: [1.1.1.1, 8.8.8.8]"])
        #expect(VMSettings.read(new).dnsServers == ["1.1.1.1", "8.8.8.8"])
    }

    @Test func eachScalarChangeTouchesOnlyItsLine() throws {
        let cases: [(VMSettingsChange, String)] = [
            (VMSettingsChange(address: true), "  address: true"),
            (VMSettingsChange(portForwarder: "grpc"), "portForwarder: grpc"),
            (VMSettingsChange(mountInotify: true), "mountInotify: true"),
        ]
        for (change, line) in cases {
            let new = try ColimaYAML.apply(change, to: template)
            #expect(changed(template, new) == [line], "\(line)")
        }
    }

    @Test func anEmptyDNSListIsWrittenAsAnEmptyList() throws {
        let text = "network:\n  dns:\n    - 1.1.1.1\n  mode: shared\n"
        let new = try ColimaYAML.apply(VMSettingsChange(dnsServers: []), to: text)
        #expect(new == "network:\n  dns: []\n  mode: shared\n")
    }

    @Test func aBlockListBecomesAFlowListAndTheNextKeyStays() throws {
        let text = "network:\n  dns:\n    - 1.1.1.1\n    # old\n    - 8.8.8.8\n  # about mode\n  mode: shared\n"
        let new = try ColimaYAML.apply(VMSettingsChange(dnsServers: ["9.9.9.9"]), to: text)
        #expect(new == "network:\n  dns: [9.9.9.9]\n  # about mode\n  mode: shared\n")
    }

    @Test func mountsAreWrittenInTheBlockForm() throws {
        let mounts = [
            VMMount(location: "~", writable: true), VMMount(location: "/Volumes/Data", writable: false),
            VMMount(location: "~/x", writable: true, mountPoint: "/x"),
        ]
        let new = try ColimaYAML.apply(VMSettingsChange(mounts: mounts), to: template)
        let block = """
            mounts:
              - location: "~"
                writable: true
              - location: /Volumes/Data
                writable: false
              - location: ~/x
                writable: true
                mountPoint: /x
            """
        #expect(new.contains(block + "\n\n# Specify a custom disk image"))
        #expect(VMSettings.read(new).mounts == mounts)
        #expect(lines(new).count == lines(template).count + 7)
    }

    @Test func aChangeOfOneMountKeepsTheMountPointOfAnother() throws {
        let text = "mounts:\n  - location: ~/a\n    writable: false\n    mountPoint: /a\n  - location: ~/b\n"
        var mounts = VMSettings.read(text).mounts
        mounts[1].writable = true
        let new = try ColimaYAML.apply(VMSettingsChange(mounts: mounts), to: text)
        #expect(VMSettings.read(new).mounts == mounts)
        #expect(new.contains("mountPoint: /a"))
    }

    @Test func emptyMountsGoBackToAnEmptyList() throws {
        let new = try ColimaYAML.apply(VMSettingsChange(mounts: []), to: "mounts:\n  - location: ~/a\ncpu: 2\n")
        #expect(new == "mounts: []\ncpu: 2\n")
    }

    @Test func aMapOfDockerKeysBecomesABlockThatKeepsTheOtherKeys() throws {
        let new = try ColimaYAML.apply(
            VMSettingsChange(registryMirrors: ["https://mirror.example.com"]), to: "docker: {}\nvmType: vz\n")
        #expect(new == "docker:\n  registry-mirrors: [\"https://mirror.example.com\"]\nvmType: vz\n")
        let other = "docker:\n  features:\n    buildkit: false\nvmType: vz\n"
        let added = try ColimaYAML.apply(VMSettingsChange(insecureRegistries: ["host:5000"]), to: other)
        #expect(
            added == "docker:\n  features:\n    buildkit: false\n  insecure-registries: [\"host:5000\"]\nvmType: vz\n")
        #expect(VMSettings.read(added).insecureRegistries == ["host:5000"])
    }

    @Test func theTemplateTakesBothRegistryListsInItsDockerSection() throws {
        let change = VMSettingsChange(registryMirrors: ["https://m.example.com"], insecureRegistries: ["10.0.0.0/8"])
        let new = try ColimaYAML.apply(change, to: template)
        let r = VMSettings.read(new)
        #expect(r.registryMirrors == ["https://m.example.com"] && r.insecureRegistries == ["10.0.0.0/8"])
        #expect(r.readOnly.isEmpty)
        // The `docker: {}` line becomes `docker:` and two children follow it.
        #expect(lines(new).count == lines(template).count + 2)
    }

    @Test func aMissingKeyGoesAtTheEndOfItsSection() throws {
        let text = "network:\n  address: false\n  # last\nvmType: vz\n"
        let new = try ColimaYAML.apply(VMSettingsChange(dnsServers: ["1.1.1.1"]), to: text)
        #expect(new == "network:\n  address: false\n  dns: [1.1.1.1]\n  # last\nvmType: vz\n")
    }

    @Test func aMissingSectionAndKeyGoAtTheEndOfTheFile() throws {
        let new = try ColimaYAML.apply(
            VMSettingsChange(dnsServers: ["1.1.1.1"], mountInotify: true), to: "cpu: 2\n# end\n")
        #expect(new == "cpu: 2\n# end\nnetwork:\n  dns: [1.1.1.1]\nmountInotify: true\n")
    }

    @Test func aFileWithoutAFinalLineEndGetsNoBlankLine() throws {
        let new = try ColimaYAML.apply(VMSettingsChange(mountInotify: true), to: "cpu: 2")
        #expect(new == "cpu: 2\nmountInotify: true")
    }

    @Test func aSectionWithOtherIndentGetsItsChildAtThatIndent() throws {
        let text = "network:\n    address: false\nvmType: vz\n"
        let new = try ColimaYAML.apply(VMSettingsChange(dnsServers: ["1.1.1.1"]), to: text)
        #expect(new == "network:\n    address: false\n    dns: [1.1.1.1]\nvmType: vz\n")
    }

    @Test func anEmptySectionValueBecomesABlock() throws {
        let new = try ColimaYAML.apply(VMSettingsChange(address: true), to: "network: {}\ncpu: 2\n")
        #expect(new == "network:\n  address: true\ncpu: 2\n")
    }

    @Test func aFileWithCRLFKeepsItsLineEnds() throws {
        let crlf = template.replacingOccurrences(of: "\n", with: "\r\n")
        let change = VMSettingsChange(dnsServers: ["1.1.1.1"], mounts: [VMMount(location: "~", writable: true)])
        let new = try ColimaYAML.apply(change, to: crlf)
        #expect(!new.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(new.contains("  dns: [1.1.1.1]\r\n"))
        #expect(VMSettings.read(new).dnsServers == ["1.1.1.1"])
        #expect(VMSettings.read(new).mounts == [VMMount(location: "~", writable: true)])
        // Only the changed lines differ from the original.
        let old = Set(lines(crlf))
        let fresh = lines(new).filter { !old.contains($0) }
        #expect(fresh.count == 4)
    }

    @Test func aChangeKeepsEveryOtherLineOfTheTemplate() throws {
        let change = VMSettingsChange(
            dnsServers: ["1.1.1.1"], address: true, portForwarder: "grpc", mountInotify: true)
        let new = try ColimaYAML.apply(change, to: template)
        #expect(changed(template, new).count == 4)
    }

    @Test func textsThatPlainYAMLWouldChangeAreQuoted() {
        #expect(ColimaYAML.quoted("~", flow: false) == "\"~\"")
        #expect(ColimaYAML.quoted("~/code", flow: false) == "~/code")
        #expect(ColimaYAML.quoted("/Volumes/My: disk", flow: false) == "\"/Volumes/My: disk\"")
        #expect(ColimaYAML.quoted("a #b", flow: false) == "\"a #b\"")
        #expect(ColimaYAML.quoted("::1", flow: true) == "\"::1\"")
        #expect(ColimaYAML.quoted("1.1.1.1", flow: true) == "1.1.1.1")
        #expect(ColimaYAML.quoted("\"x\"", flow: false) == "\"\\\"x\\\"\"")
    }

    @Test func aQuotedValueIsReadBack() throws {
        let weird = ["/Volumes/My: disk", "~", "/a\\b", "/say \"x\""]
        let mounts = weird.map { VMMount(location: $0) }
        let new = try ColimaYAML.apply(VMSettingsChange(mounts: mounts), to: "cpu: 2\n")
        #expect(VMSettings.read(new).mounts == mounts)
    }

    // MARK: three states of mounts

    @Test func aFileWithNoMountsKeyAndANullKeyMountNothing() throws {
        for text in ["cpu: 2\n", "cpu: 2\nmounts:\n", "cpu: 2\nmounts: null\n"] {
            let r = VMSettings.read(text)
            #expect(r.mounts.isEmpty && !r.mountsDefaultHome, "\(text)")
        }
    }

    @Test func anExplicitEmptyListIsTheHomeFolderDefault() {
        let r = VMSettings.read("cpu: 2\nmounts: []\n")
        #expect(r.mounts.isEmpty && r.mountsDefaultHome)
    }

    @Test func theFirstMountOfAFileWithNoMountsGoesInAlone() throws {
        for text in ["cpu: 2\n", "cpu: 2\nmounts: null\n"] {
            let new = try ColimaYAML.apply(VMSettingsChange(mounts: [VMMount(location: "/Volumes/Data")]), to: text)
            #expect(VMSettings.read(new).mounts == [VMMount(location: "/Volumes/Data")], "\(text)")
            #expect(!VMSettings.read(new).mountsDefaultHome)
        }
    }

    // MARK: keys that the editor does not see

    @Test func aTabAfterTheColonIsStillTheKey() throws {
        let text = "network:\n  dns:\t[8.8.8.8]\n"
        #expect(VMSettings.read(text).dnsServers == ["8.8.8.8"])
        let new = try ColimaYAML.apply(VMSettingsChange(dnsServers: ["1.1.1.1"]), to: text)
        #expect(new == "network:\n  dns: [1.1.1.1]\n")
    }

    @Test(arguments: ["network:\n  \"dns\": [8.8.8.8]\n", "network:\n  'dns': [8.8.8.8]\n"])
    func aQuotedKeyMakesTheFieldReadOnlyInsteadOfAddingASecondKey(text: String) {
        let r = VMSettings.read(text)
        #expect(!r.isEditable(.dnsServers))
        #expect(throws: ColimaYAML.Failure.unsupported("network.dns")) {
            try ColimaYAML.apply(VMSettingsChange(dnsServers: ["1.1.1.1"]), to: text)
        }
    }

    @Test func aQuotedKeyOfAnotherNameChangesNothing() throws {
        let text = "network:\n  \"other\": 1\n"
        let new = try ColimaYAML.apply(VMSettingsChange(dnsServers: ["1.1.1.1"]), to: text)
        #expect(new == "network:\n  \"other\": 1\n  dns: [1.1.1.1]\n")
    }
}
