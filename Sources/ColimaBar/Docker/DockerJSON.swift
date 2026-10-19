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
    let ip_address: String?
}

// Docker Engine API payloads (only the fields we use).

struct APIInfo: Decodable {
    /// The clock of the VM, in RFC 3339 format.
    let SystemTime: String?
    /// The CPU architecture of the VM, for example `aarch64` or `x86_64`.
    let Architecture: String?
}

/// `GET /volumes/NAME`.
struct APIVolume: Decodable {
    let Name: String
    let Driver: String?
    let Labels: [String: String]?
    let CreatedAt: String?
    /// The driver options, for example a bind folder or an NFS address.
    let Options: [String: String]?

    /// True for a plain `local` volume that ColimaBar can delete and create again.
    var isPlain: Bool { (Driver ?? "local") == "local" && (Options ?? [:]).isEmpty }
}

/// The reply of `POST /containers/create`.
struct APIIdResponse: Decodable {
    let Id: String
}

/// The error reply of the daemon: `{"message":"…"}`.
struct APIMessage: Decodable {
    let message: String?
}

struct APIContainer: Decodable {
    struct Port: Decodable {
        let IP: String?
        let PublicPort: Int?
        let PrivatePort: Int?
        /// "tcp", "udp" or "sctp".
        let `Type`: String?
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

/// The part of `GET /containers/{id}/json` that `RemovedLogKeeper` reads.
struct APIInspect: Decodable {
    struct Host: Decodable {
        /// True for `docker run --rm`: Docker removes the container when it exits.
        let AutoRemove: Bool?
    }
    struct Cfg: Decodable {
        let Tty: Bool?
    }
    let HostConfig: Host?
    let Config: Cfg?
}

/// `GET /containers/{id}/json`, the fields that the Inspect page shows.
struct APIContainerDetail: Decodable {
    struct Health: Decodable {
        struct Entry: Decodable {
            let Start: String?
            let ExitCode: Int?
            let Output: String?
        }
        let Status: String?
        let FailingStreak: Int?
        let Log: [Entry]?
    }
    struct State: Decodable {
        let Status: String?
        let OOMKilled: Bool?
        let ExitCode: Int?
        let Error: String?
        let StartedAt: String?
        let FinishedAt: String?
        let Health: Health?
    }
    struct RestartPolicy: Decodable {
        let Name: String?
        let MaximumRetryCount: Int?
    }
    struct Host: Decodable {
        let RestartPolicy: RestartPolicy?
        let Privileged: Bool?
        let Memory: Int64?
        let MemoryReservation: Int64?
        let NanoCpus: Int64?
        let CpuShares: Int64?
        let PidsLimit: Int64?
    }
    /// A list of words. Older API versions sent a single string for
    /// `Entrypoint`.
    struct Words: Decodable {
        let values: [String]
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let list = try? c.decode([String].self) {
                values = list
            } else {
                values = (try? c.decode(String.self)).map { [$0] } ?? []
            }
        }
    }
    struct Cfg: Decodable {
        let Image: String?
        let Env: [String]?
        let Cmd: Words?
        let Entrypoint: Words?
        let WorkingDir: String?
        let User: String?
        let Labels: [String: String]?
    }
    struct Mount: Decodable {
        let `Type`: String?
        let Name: String?
        let Source: String?
        let Destination: String?
        let RW: Bool?
    }
    struct Endpoint: Decodable {
        let IPAddress: String?
        let GlobalIPv6Address: String?
        let Aliases: [String]?
        let DNSNames: [String]?
    }
    struct Binding: Decodable {
        let HostIp: String?
        let HostPort: String?
    }
    struct Net: Decodable {
        let Networks: [String: Endpoint]?
        let Ports: [String: [Binding]?]?
    }
    let Id: String
    let Name: String?
    let Created: String?
    /// The ID of the image, `sha256:…`.
    let Image: String?
    let RestartCount: Int?
    let State: State?
    let HostConfig: Host?
    let Config: Cfg?
    let Mounts: [Mount]?
    let NetworkSettings: Net?
}

/// `GET /images/{id}/json`, the part that gives the digests.
struct APIImageDetail: Decodable {
    let RepoDigests: [String]?
}
