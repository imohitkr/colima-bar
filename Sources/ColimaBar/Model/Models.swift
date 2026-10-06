import Foundation

struct VMInfo: Equatable {
    var arch = ""
    var runtime = ""
    var cpus = 0
    var memGB = 0
    var diskGB = 0
    var driver = ""
    var mountType = ""
}

struct Container: Identifiable, Equatable {
    let id: String
    let name: String
    let image: String
    let state: String  // running, exited, created, paused, restarting
    let status: String  // "Up 3 hours (healthy)"
    let ports: [Int]
    let project: String?  // docker compose project label
    /// "healthy", "unhealthy", "health: starting" or nil. Parsed once here,
    /// not on every read: rows read it several times per render.
    let health: String?

    init(id: String, name: String, image: String, state: String, status: String, ports: [Int], project: String?) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.ports = ports
        self.project = project
        health = Self.health(status: status)
    }

    var isRunning: Bool { state == "running" || state == "restarting" || state == "paused" }

    static func health(status: String) -> String? {
        for h in ["unhealthy", "healthy", "health: starting"] where status.contains("(\(h))") { return h }
        return nil
    }
}

struct AlertItem: Identifiable, Equatable {
    let id = UUID()
    let date = Date()
    let title: String
    let body: String
    let containerID: String?
}

struct ProfileRow: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let isRunning: Bool
    let cpus: Int
    let memGB: Int
}

struct Stat: Equatable {
    let cpu: Double  // percent of one core, as docker reports it
    let memBytes: Double
}

struct DFRow: Identifiable, Equatable {
    var id: String { type }
    let type: String
    let count: Int
    let size: Double
    let reclaimable: Double
}

struct ImageRow: Identifiable, Equatable {
    let id: String
    let repo: String
    let tag: String
    let size: Double
    let created: Date
    let containers: Int
    var dangling: Bool { repo == "<none>" }
    var ref: String {
        dangling ? String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12)) : "\(repo):\(tag)"
    }
}

struct VolumeRow: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let size: Double
    let links: Int
    let project: String?
    let isAnonymous: Bool
}
