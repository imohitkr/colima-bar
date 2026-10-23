import Observation

/// The state of the VM settings page. It lives in `ViewState`, so it
/// survives the popover closing (the folder panel closes it).
@MainActor @Observable
final class VMConfigForm {
    var dnsText = ""
    var address = false
    var portForwarder = "ssh"
    var mounts: [VMMount] = []
    var mountInotify = false
    var mirrorsText = ""
    var insecureText = ""
    /// The picks of the VM type section. They are not part of `change`, so
    /// Apply ignores them: a change needs a recreate.
    var vmType = "vz"
    var mountType = "virtiofs"

    /// The values of colima.yaml that the fields started from.
    private(set) var baseline = VMSettings.Read()
    /// The SHA-256 of the colima.yaml of `baseline`. `applyVMSettings` refuses
    /// to write if the file is different at Apply.
    private(set) var baselineSHA: String?
    /// The profile of `baseline`, or nil before the first `load`.
    private(set) var profile: String?

    /// Splits a text with commas or blanks into items, without empty ones.
    static func items(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }

    /// Shows the values of colima.yaml and drops the edits.
    func load(_ read: VMSettings.Read, sha: String? = nil, profile: String) {
        baseline = read
        baselineSHA = sha
        self.profile = profile
        revert()
    }

    /// True if the page must show `read` and drop the edits: the profile is
    /// another one, or nothing is edited, or the edits are the values that
    /// the file has now (a good Apply, or the same edit in an editor).
    func shouldReload(for read: VMSettings.Read, profile: String) -> Bool {
        self.profile != profile || !isDirty || matches(read)
    }

    /// True if every field has the value that `read` has.
    private func matches(_ read: VMSettings.Read) -> Bool {
        Self.items(dnsText) == read.dnsServers && address == read.address && portForwarder == read.portForwarder
            && mounts == read.mounts && mountInotify == read.mountInotify
            && Self.items(mirrorsText) == read.registryMirrors && Self.items(insecureText) == read.insecureRegistries
    }

    /// True if Apply may run. The checks of `applyVMSettings` come first in
    /// the list, so the button never promises what the model refuses.
    static func canApply(isDirty: Bool, problems: [String], busy: Bool, isDebug: Bool, hasFile: Bool) -> Bool {
        isDirty && problems.isEmpty && !busy && !isDebug && hasFile
    }

    /// Sets every field to its value in colima.yaml.
    func revert() {
        dnsText = baseline.dnsServers.joined(separator: ", ")
        address = baseline.address
        portForwarder = baseline.portForwarder
        mounts = baseline.mounts
        mountInotify = baseline.mountInotify
        mirrorsText = baseline.registryMirrors.joined(separator: ", ")
        insecureText = baseline.insecureRegistries.joined(separator: ", ")
        let types = VMTypeRules.effective(vmType: baseline.vmType, mountType: baseline.mountType)
        vmType = types.vmType
        mountType = types.mountType
    }

    /// The fields that you changed. A read-only field never counts.
    var change: VMSettingsChange {
        var c = VMSettingsChange()
        func differs<T: Equatable>(_ field: VMSettings.Field, _ now: T, _ was: T) -> T? {
            baseline.isEditable(field) && now != was ? now : nil
        }
        c.dnsServers = differs(.dnsServers, Self.items(dnsText), baseline.dnsServers)
        c.address = differs(.address, address, baseline.address)
        c.portForwarder = differs(.portForwarder, portForwarder, baseline.portForwarder)
        c.mountInotify = differs(.mountInotify, mountInotify, baseline.mountInotify)
        c.mounts = differs(.mounts, mounts, baseline.mounts)
        c.registryMirrors = differs(.registryMirrors, Self.items(mirrorsText), baseline.registryMirrors)
        c.insecureRegistries = differs(.insecureRegistries, Self.items(insecureText), baseline.insecureRegistries)
        return c
    }

    var isDirty: Bool { !change.isEmpty }

    /// True if an empty list means your home folder. Colima 0.10.3 mounts it
    /// for `mounts: []`. If colima.yaml has no `mounts` key, or `null`, it
    /// mounts nothing.
    var emptyListMountsHome: Bool { baseline.mountsDefaultHome || !baseline.mounts.isEmpty }

    /// Adds a folder. If an empty list means your home folder, a list
    /// replaces that default, so the list starts with `~`. For a file with no
    /// mounts, only the new folder goes in.
    func addMount(_ path: String) {
        if mounts.isEmpty, emptyListMountsHome, path != "~" { mounts.append(VMMount(location: "~", writable: true)) }
        guard !mounts.contains(where: { $0.location == path }) else { return }
        mounts.append(VMMount(location: path))
    }

    func removeMount(at index: Int) {
        guard mounts.indices.contains(index) else { return }
        mounts.remove(at: index)
    }
}
