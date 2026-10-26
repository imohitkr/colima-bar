import Foundation

/// When ColimaBar may contact a cluster.
enum KubeRules {
    /// True only for the context of a Colima profile whose VM runs. Its API
    /// is a Lima port forward, so the call starts no VM. Any other cluster
    /// stays untouched.
    static func mayListNamespaces(context: String, runningProfiles: Set<String>) -> Bool {
        runningProfiles.contains { Paths.kubeContext($0) == context }
    }
}
