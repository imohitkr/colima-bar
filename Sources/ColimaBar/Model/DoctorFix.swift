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

    var label: String {
        switch self {
        case .useColimabar: "Use colimabar"
        case .setRoutes: "Set routes"
        case .copyLine: "Copy line"
        case .useOsxkeychain: "Use osxkeychain"
        case .addPluginFolder: "Add folder"
        case .repair: "Repair…"
        }
    }
}
