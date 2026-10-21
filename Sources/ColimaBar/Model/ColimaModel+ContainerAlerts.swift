import Foundation

/// The glue between the events of dockerd and `ContainerAlertGate`.
extension ColimaModel {
    /// Feeds one container event to the gate and posts what it decides.
    /// `notify` is the crash notification setting: the gate sees every event
    /// even when it is off, so its state stays right.
    func reactToContainerEvent(_ ev: DockerEvent, attrs: [String: String], notify: Bool) {
        guard let id = ev.Actor?.ID else { return }
        alertGate.recoveryEnabled = notifyOnRecovery
        // A destroyed container gets no late alert from a waiting check.
        if ev.Action == "destroy" { deferredUnhealthy[id] = nil }
        let input = ContainerAlertInput(
            id: id, action: ev.Action ?? "", exitCode: attrs["exitCode"], signal: attrs["signal"], now: Date())
        let ref = ContainerRef(id: id, name: attrs["name"] ?? "container")
        let project = attrs["com.docker.compose.project"]
        switch alertGate.react(input) {
        case .none: break
        case .post(let outcome): if notify { deliver(outcome, ref: ref, project: project) }
        case .recheckUnhealthy(let after): if notify { recheckUnhealthy(ref: ref, project: project, after: after) }
        }
    }

    /// The key in `mutedProjects`, or nil for a container without a project.
    func muteKey(project: String?) -> String? {
        guard let project, !project.isEmpty else { return nil }
        return Self.composeKey(profile: profile, name: project)
    }

    func isMuted(project: String) -> Bool {
        muteKey(project: project).map(mutedProjects.contains) ?? false
    }

    /// Stops or starts the banners of a Compose project. The dashboard's list
    /// of alerts still shows them.
    func setMuted(_ on: Bool, project: String) {
        guard let key = muteKey(project: project) else { return }
        mutedProjects = MutedProjects.toggled(mutedProjects, key: key, muted: on)
    }

    private func deliver(_ outcome: ContainerAlertOutcome, ref: ContainerRef, project: String?) {
        let banner = !(project.map(isMuted) ?? false)
        let sent = Notifier.shared.post(
            outcome.body, title: ref.name, container: ref, profile: profile, record: !outcome.isRecovery,
            banner: banner)
        if ContainerAlertGate.marksUnhealthyAlerted(outcome: outcome, sent: sent) {
            alertGate.markUnhealthyAlerted(ref.id)
        }
    }

    /// An unhealthy event inside the start grace waits for its end. Then the
    /// container must still be unhealthy. One id has one waiting task. A
    /// `destroy` or a stopped VM ends the wait without an alert.
    private func recheckUnhealthy(ref: ContainerRef, project: String?, after: TimeInterval) {
        guard deferredUnhealthy[ref.id] == nil else { return }
        let token = UUID()
        deferredUnhealthy[ref.id] = token
        let gen = generation
        Task { @MainActor in
            // The task is current while its generation, its token and a running VM hold.
            @MainActor func current() -> Bool {
                guard generation == gen, deferredUnhealthy[ref.id] == token else { return false }
                if state == .running { return true }
                deferredUnhealthy[ref.id] = nil
                return false
            }
            try? await Task.sleep(for: .seconds(after))
            guard current() else { return }
            var fresh = await refreshContainers()
            if !fresh {
                // One more try. If the list stays out of reach, the alert goes out unchecked.
                try? await Task.sleep(for: .seconds(15))
                guard current() else { return }
                fresh = await refreshContainers()
            }
            guard current() else { return }
            let unhealthy = container(withID: ref.id)?.health == "unhealthy"
            // After the decision, so a second event during the await cannot post twice.
            deferredUnhealthy[ref.id] = nil
            guard notifyOnCrash,
                ContainerAlertGate.shouldPostDeferredUnhealthy(
                    vmRunning: true, stillWaiting: true, listFresh: fresh, stillUnhealthy: unhealthy)
            else { return }
            let input = ContainerAlertInput(
                id: ref.id, action: "health_status: unhealthy", exitCode: nil, signal: nil, now: Date())
            switch alertGate.react(input) {
            case .none: break
            case .post(let outcome): deliver(outcome, ref: ref, project: project)
            case .recheckUnhealthy(let again): recheckUnhealthy(ref: ref, project: project, after: again)
            }
        }
    }
}
