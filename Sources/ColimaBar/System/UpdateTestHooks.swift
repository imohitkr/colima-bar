#if COLIMABAR_UPDATE_TEST
    import Foundation

    /// Only a test build has this file (`COLIMABAR_UPDATE_TEST=1 ./build.sh`
    /// passes `-DCOLIMABAR_UPDATE_TEST`). A release build must not contain
    /// it: CI checks the binary for the name of the variable.
    ///
    /// The variable moves the release API and the download to a local
    /// server, so a person can try an update without a release.
    enum UpdateTestHooks {
        /// `http://127.0.0.1:PORT` from the environment. Only that form works.
        static let base: URL? = {
            guard let raw = ProcessInfo.processInfo.environment["COLIMABAR_UPDATE_BASE"],
                let c = URLComponents(string: raw),
                c.scheme == "http", c.host == "127.0.0.1", c.port != nil,
                c.user == nil, c.password == nil, c.path.isEmpty || c.path == "/"
            else { return nil }
            return URL(string: "http://127.0.0.1:\(c.port!)")
        }()
    }
#endif
