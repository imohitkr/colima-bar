/// A change that Doctor can make for one check. Each fix has a button.
enum DoctorFix: Equatable, Sendable {
    /// Switches the docker CLI to the `colimabar` context.
    case useColimabar
    /// Sets the launchd and testcontainers routes (`Routing.apply`).
    case setRoutes
    /// Copies the `export DOCKER_HOST=…` line for the ColimaBar socket.
    case copyLine
    /// Sets `credsStore` to `osxkeychain` in the docker config file.
    case useOsxkeychain
    /// Adds the Homebrew plugin folder to `cliPluginsExtraDirs`.
    case addPluginFolder
    /// Runs `colima-ctl.sh repair` (the same as the Repair button).
    case repair
    /// Restarts the VM, so Colima forwards the ports again or the VM reads the DNS of the Mac again.
    case restartVM
    /// Sets `portForwarder: ssh` in colima.yaml and restarts the VM.
    case useSSHForwarder
    /// Clears `network.dns` in colima.yaml, so the VM uses the DNS of the Mac, and restarts the VM.
    case useMacDNS

    /// A fixed name for scripts: the `fix` field of `colimabar doctor --json`.
    /// Do not change a value.
    var id: String {
        switch self {
        case .useColimabar: "useColimabar"
        case .setRoutes: "setRoutes"
        case .copyLine: "copyLine"
        case .useOsxkeychain: "useOsxkeychain"
        case .addPluginFolder: "addPluginFolder"
        case .repair: "repair"
        case .restartVM: "restartVM"
        case .useSSHForwarder: "useSSHForwarder"
        case .useMacDNS: "useMacDNS"
        }
    }

    var label: String {
        switch self {
        case .useColimabar: "Use colimabar"
        case .setRoutes: "Set routes"
        case .copyLine: "Copy line"
        case .useOsxkeychain: "Use osxkeychain"
        case .addPluginFolder: "Add folder"
        case .repair: "Repair…"
        case .restartVM: "Restart"
        case .useSSHForwarder: "Use ssh forwarder"
        case .useMacDNS: "Use the Mac's DNS"
        }
    }
}
