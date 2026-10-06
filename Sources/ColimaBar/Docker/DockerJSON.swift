// swift-format-ignore-file: AlwaysUseLowerCamelCase
// Property names match the JSON keys of the wire format.

import Foundation

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
    struct Port: Decodable {
        let IP: String?
        let PublicPort: Int?
    }
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
    struct Ctr: Decodable {
        let SizeRw: Int64?
        let State: String
    }
    struct Volume: Decodable {
        struct Usage: Decodable {
            let Size: Int64
            let RefCount: Int
        }
        let Name: String
        let Labels: [String: String]?
        let UsageData: Usage?
    }
    struct Cache: Decodable {
        let Size: Int64
        let InUse: Bool
        let Shared: Bool
    }
    let Images: [Image]?
    let Containers: [Ctr]?
    let Volumes: [Volume]?
    let BuildCache: [Cache]?
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
