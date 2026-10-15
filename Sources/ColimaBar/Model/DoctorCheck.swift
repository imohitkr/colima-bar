/// The checks of Doctor, in the order that Doctor shows them.
enum DoctorCheck: String, CaseIterable, Sendable {
    case tools
    case context
    case appRoutes
    case shellHost
    case credentials
    case plugins
    case vmStatus
    case staleFiles
    case diskSpace

    var title: String {
        switch self {
        case .tools: "Tools"
        case .context: "Docker context"
        case .appRoutes: "App routes"
        case .shellHost: "Shell DOCKER_HOST"
        case .credentials: "Registry login"
        case .plugins: "Docker plugins"
        case .vmStatus: "VM status"
        case .staleFiles: "Stale Lima files"
        case .diskSpace: "Disk space"
        }
    }
}
