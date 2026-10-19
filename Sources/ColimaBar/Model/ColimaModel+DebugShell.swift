import Foundation

/// The debug shell of a running container: a terminal window with a shell in
/// a new container that shares the processes and the network of the target.
/// `colima-ctl.sh ctr-debug` runs it on the profile socket of Colima, so it
/// never starts a stopped VM.
extension ColimaModel {
    /// What a click on **Debug shell** does. `args` is nil when nothing must
    /// run. `notice` is a message for the user. A bad image name gives the
    /// notice only once for each stored value (`lastWarned`).
    nonisolated static func debugShellPlan(
        state: String, isDebug: Bool, stored: String?, lastWarned: String?, id: String
    ) -> (args: [String]?, notice: String?) {
        guard state == "running", !isDebug else { return (nil, nil) }
        let (image, invalid) = DebugShell.image(stored: stored)
        var notice: String?
        if invalid, lastWarned != stored {
            notice = "The debugShellImage setting is not a valid image name. ColimaBar uses busybox."
        }
        guard let args = DebugShell.ctlArgs(id: id, image: image) else {
            return (nil, "Debug shell failed: the container ID is not valid.")
        }
        return (args, notice)
    }

    func debugShell(_ c: Container) {
        let stored = Defaults.string(.debugShellImage)
        let plan = Self.debugShellPlan(
            state: c.state, isDebug: isDebug, stored: stored, lastWarned: debugImageWarned, id: c.id)
        if DebugShell.image(stored: stored).invalid { debugImageWarned = stored }
        if let notice = plan.notice { notify(notice) }
        if let args = plan.args { terminal(.containerDebug, args[0], args[1]) }
    }
}
