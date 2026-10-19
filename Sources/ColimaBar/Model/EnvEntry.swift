import Foundation

/// One `KEY=value` entry of the environment of a container. It keeps the raw
/// value, so it lives only in the Inspect page and never in the model, the
/// status file or the diagnostics.
struct EnvEntry: Equatable, Sendable {
    let key: String
    let value: String
    /// The page hides the value until the user shows it.
    let isSecret: Bool
}
