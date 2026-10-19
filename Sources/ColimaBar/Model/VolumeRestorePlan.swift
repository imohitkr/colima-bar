import Foundation

/// What a restore may do with its target volume. The rules are pure, so a
/// test can check each one.
enum VolumeRestorePlan: Equatable {
    /// The volume does not exist: ColimaBar creates it.
    case createNew
    /// The volume exists and has no files. Containers may use it.
    case useEmpty
    /// The volume has files and no container uses it. ColimaBar asks, then
    /// deletes the volume, creates it again and restores.
    case confirmReplace
    /// Containers use the volume. A restore under them could break them.
    case refuse(users: [String])

    /// `isEmpty` and `users` matter only if the volume exists. `users` are the
    /// names of the containers that use it.
    static func decide(exists: Bool, isEmpty: Bool, users: [String]) -> VolumeRestorePlan {
        guard exists else { return .createNew }
        if isEmpty { return .useEmpty }
        return users.isEmpty ? .confirmReplace : .refuse(users: users)
    }
}
