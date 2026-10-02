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
    let state: String       // running, exited, created, paused, restarting
    let status: String      // "Up 3 hours (healthy)"
    let ports: [Int]
    let project: String?    // docker compose project label

    var isRunning: Bool { state == "running" || state == "restarting" || state == "paused" }
    var health: String? {
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
    let running: Bool
    let cpus: Int
    let memGB: Int
}

struct Stat: Equatable {
    let cpu: Double     // percent of one core, as docker reports it
    let memBytes: Double
}

struct DFRow: Identifiable, Equatable {
    var id: String { type }
    let type: String
    let count: Int
    let size: Double
    let reclaimable: Double
}

// MARK: - Raw docker/colima JSON

struct ColimaListJSON: Decodable {
    let name: String?
    let status: String
    let arch: String?
    let cpus: Int?
    let memory: Int64?
    let disk: Int64?
    let runtime: String?
}

struct ColimaStatusJSON: Decodable {
    let driver: String?
    let mount_type: String?
}

// Docker Engine API payloads (only the fields we use).

struct APIContainer: Decodable {
    struct Port: Decodable { let IP: String?; let PublicPort: Int? }
    let Id: String
    let Names: [String]
    let Image: String
    let State: String
    let Status: String
    let Ports: [Port]?
    let Labels: [String: String]?
}

struct APIStats: Decodable {
    struct CPU: Decodable {
        struct Usage: Decodable { let total_usage: UInt64 }
        let cpu_usage: Usage
        let system_cpu_usage: UInt64?
        let online_cpus: Int?
    }
    struct Mem: Decodable {
        let usage: UInt64?
        let stats: [String: UInt64]?
    }
    let cpu_stats: CPU
    let precpu_stats: CPU
    let memory_stats: Mem

    /// Same formulas as `docker stats`: CPU% of one core, memory minus page cache.
    var cpuPercent: Double {
        // The first sample of a stream has no previous one; a delta against
        // zero would be the container's lifetime average, not current load.
        guard let prevSys = precpu_stats.system_cpu_usage, prevSys > 0 else { return 0 }
        let cpuDelta = Double(cpu_stats.cpu_usage.total_usage) - Double(precpu_stats.cpu_usage.total_usage)
        let sysDelta = Double(cpu_stats.system_cpu_usage ?? 0) - Double(prevSys)
        guard cpuDelta > 0, sysDelta > 0 else { return 0 }
        return cpuDelta / sysDelta * Double(cpu_stats.online_cpus ?? 1) * 100
    }

    var memBytes: Double {
        let usage = Double(memory_stats.usage ?? 0)
        let cache = Double(memory_stats.stats?["inactive_file"] ?? memory_stats.stats?["total_inactive_file"] ?? 0)
        return max(usage - cache, 0)
    }
}

struct APIDF: Decodable {
    struct Image: Decodable {
        let Id: String
        let RepoTags: [String]?
        let Size: Int64
        let SharedSize: Int64?
        let Created: Int64
        let Containers: Int
    }
    struct Ctr: Decodable { let SizeRw: Int64?; let State: String }
    struct Volume: Decodable {
        struct Usage: Decodable { let Size: Int64; let RefCount: Int }
        let Name: String
        let Labels: [String: String]?
        let UsageData: Usage?
    }
    struct Cache: Decodable { let Size: Int64; let InUse: Bool; let Shared: Bool }
    let Images: [Image]?
    let Containers: [Ctr]?
    let Volumes: [Volume]?
    let BuildCache: [Cache]?
}

struct ImageRow: Identifiable, Equatable {
    let id: String
    let repo: String
    let tag: String
    let size: Double
    let created: Date
    let containers: Int
    var dangling: Bool { repo == "<none>" }
    var ref: String { dangling ? String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12)) : "\(repo):\(tag)" }
}

struct VolumeRow: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let size: Double
    let links: Int
    let project: String?
    let anonymous: Bool
}

struct DockerEvent: Decodable {
    struct Actor: Decodable {
        let ID: String?
        let Attributes: [String: String]?
    }
    let `Type`: String?
    let Action: String?
    let Actor: Actor?
}

// MARK: - Parsing helpers

enum Parse {
    /// Top-level `key: value` from colima.yaml, or the value under a section.
    static func yaml(_ text: String, key: String, section: String? = nil) -> String? {
        var inSection = section == nil
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let section {
                if line.hasPrefix("\(section):") { inSection = true; continue }
                if inSection, let c = line.first, c.isLetter { inSection = false }
                if inSection, line.hasPrefix("  \(key):") {
                    return line.dropFirst(key.count + 3).trimmingCharacters(in: .whitespaces)
                }
            } else if line.hasPrefix("\(key):") {
                return line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

enum Fmt {
    static func bytes(_ b: Double) -> String {
        if b <= 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = b, i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(Int(v)) B" : String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, units[i])
    }
}
