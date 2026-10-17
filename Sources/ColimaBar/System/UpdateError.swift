import Foundation

/// Why an in-app update stopped. `message` is the text for the notification.
enum UpdateError: Error, Equatable {
    /// The user cancelled. Nothing shows.
    case cancelled
    case network(String)
    case notEnoughSpace
    case sizeMismatch
    case digestMismatch
    case attestationFailed
    /// `gh` could not run the attestation check that the dialog promised
    /// (no network, a time-out, or a login problem). The text says why.
    case attestationUnavailable(String)
    case unpackFailed(String)
    case signatureInvalid
    case bundleInvalid(String)
    /// An open VM action or similar work did not end in time.
    case blocked(String)
    /// macOS did not allow the change (App Management or a permission).
    case macOSBlocked
    case swapFailed(String)
    /// The swap failed, and the old bundle could not go back to its place.
    /// The text is the path that holds the old bundle now.
    case rollbackFailed(String)
    /// A step failed for a reason that is not a verification problem, for
    /// example a full disk. Nothing was installed.
    case other(String)

    var message: String {
        switch self {
        case .cancelled: "You cancelled the update."
        case .network(let why): "The download failed: \(why)"
        case .notEnoughSpace: "The disk has too little free space for the update."
        case .sizeMismatch: "The download has a different size than GitHub lists for it."
        case .digestMismatch: "The SHA-256 digest of the download is not the one that GitHub lists."
        case .attestationFailed:
            "The download is not from a build of this repository (gh attestation verify failed)."
        case .attestationUnavailable(let why):
            "ColimaBar could not run the build attestation check that it promised: \(why). Try again later."
        case .unpackFailed(let why): "ColimaBar could not unpack the download: \(why)."
        case .signatureInvalid: "The signature of the downloaded app is not valid."
        case .bundleInvalid(let why): "The downloaded app is not the expected release: \(why)."
        case .blocked(let why): "ColimaBar waited 2 minutes. \(why). ColimaBar did not restart."
        case .macOSBlocked: "macOS did not allow the change to the app folder."
        case .swapFailed(let why): "ColimaBar could not replace the app: \(why)."
        case .rollbackFailed(let path):
            "ColimaBar could not put the old version back. The old version is at \(path). See the troubleshooting page."
        case .other(let why): "The update stopped: \(why)."
        }
    }

    /// After these errors the offer changes to the release page until the
    /// next launch. A network problem, a cancel, a missing attestation check
    /// and busy work can pass, so the install button stays.
    var usesReleasePageAfter: Bool {
        switch self {
        case .cancelled, .network, .notEnoughSpace, .blocked, .attestationUnavailable, .other: false
        case .sizeMismatch, .digestMismatch, .attestationFailed, .unpackFailed, .signatureInvalid, .bundleInvalid,
            .macOSBlocked, .swapFailed, .rollbackFailed:
            true
        }
    }

    /// The error that ends an install, for any error `error` that a step
    /// threw. A cancel wins over everything: after a cancel, a step can end
    /// with another error, and that must not show.
    static func ending(_ error: any Error, cancelled: Bool) -> UpdateError {
        if cancelled || error is CancellationError { return .cancelled }
        if let e = error as? UpdateError { return e }
        return .other(error.localizedDescription)
    }
}
