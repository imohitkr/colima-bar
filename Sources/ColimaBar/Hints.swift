import SwiftUI

/// What the pointer is over. Shown in the dashboard's hint bar the moment you
/// hover, and also attached as a native tooltip.
@MainActor @Observable
final class Hint {
    static let shared = Hint()
    var text: String?
}

extension View {
    /// Explains this control: instantly in the hint bar, and as a tooltip.
    func hint(_ text: String) -> some View {
        self
            .help(text)
            .onHover { inside in
                let h = Hint.shared
                if inside {
                    h.text = text
                } else if h.text == text {
                    h.text = nil
                }
            }
    }
}

/// Fixed-height strip above the footer, so hovering never shifts the layout.
struct HintBar: View {
    let hint = Hint.shared

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: hint.text == nil ? "cursorarrow.rays" : "info.circle.fill")
                .foregroundStyle(hint.text == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
            Text(hint.text ?? "Hover over anything to see what it does.")
                .foregroundStyle(hint.text == nil ? .tertiary : .secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(height: 50, alignment: .topLeading)
        .background(.quaternary.opacity(0.25))
    }
}

/// Every explanation in one place, so wording stays consistent.
enum Help {
    // VM
    static let restart = "Restart the Colima VM. Running containers stop and only come back if they have a restart policy."
    static let stopVM = "Stop the Colima VM and every container in it. Frees the CPU and memory it was using."
    static let startVM = "Boot the Colima VM using the settings in colima.yaml."
    static let subtitle = "The VM's allocated CPUs, memory and disk, its architecture, and how your Mac's files are shared into it (virtiofs is the fast native option)."

    // Tiles
    static let cpuTile = "CPU used by all running containers together, as a share of the VM's total. 100% means every VM core is busy."
    static let memTile = "Memory used by all running containers, excluding reclaimable page cache (the same figure docker stats shows). The graph shows it as a share of VM memory."
    static let ctrTile = "Running and stopped containers. Unhealthy means a container's HEALTHCHECK is failing."

    // Tabs / filter
    static let tabs = "Containers: what's running. Images: what's downloaded. Volumes: persistent data. System: VM settings and cleanup."
    static let runningOnly = "Hide stopped and exited containers."
    static let search = "Filter by name, image or compose project. ⌘F focuses this field."

    // Containers
    static let projectGroup = "Containers started by docker compose, grouped by project. The buttons act on the whole project."
    static let standalone = "Containers not started by docker compose."
    static let ctrCPU = "CPU as % of one core, like docker stats: 200% means two cores fully busy."
    static let ctrMem = "Memory the container is using now, excluding reclaimable page cache."
    static func port(_ p: Int) -> String { "Open http://localhost:\(p) in your browser. This host port is published from the container." }
    static let healthy = "HEALTHCHECK is passing."
    static let unhealthy = "HEALTHCHECK is failing. The container is running but probably not working; check its logs."
    static let starting = "HEALTHCHECK hasn't passed yet; the container is still starting up."
    static let logs = "Follow the container's logs (last 200 lines, then live) in iTerm."
    static let shell = "Open an interactive shell (bash if present, otherwise sh) inside the container in iTerm."
    static let ctrRestart = "Restart this container. Its filesystem and volumes are kept."
    static let ctrStop = "Stop this container (SIGTERM, then SIGKILL after 10s). It can be started again."
    static let ctrStart = "Start this stopped container again with its original settings."
    static let ctrRemove = "Delete this container. Its writable layer is lost; named volumes are kept."
    static let more = "Copy name, ID, image or an exec command; open ports; remove."
    static let stopAll = "Stop every running container. Asks first."

    // Images
    static let inUse = "At least one container (running or stopped) uses this image, so it can't be removed or pruned."
    static let dangling = "Untagged leftover layers, usually from rebuilding an image with the same tag. Safe to remove."
    static let removeDangling = "Remove untagged images and the build cache. Nothing in use is touched."
    static let removeUnusedImages = "Remove every image no container uses. They'll be pulled again next time you need them."
    static let imageSize = "Size on disk. Images that share base layers share that space, so the total can be less than the sum."

    // Volumes
    static let anonymous = "An unnamed volume Docker created for a VOLUME line in an image. Often left behind after containers are removed."
    static let unusedVolume = "No container references this volume. Removing it deletes its data for good."
    static let removeUnusedVolumes = "Delete every volume no container uses. The data in them is lost for good, so it asks first."

    // System: resources
    static let presets = "Quick sizes. Light: a couple of small services. Standard: a typical dev stack such as a database, a few services and builds. Heavy: large builds, Kubernetes or many containers. Applying restarts the VM."
    static let cpu = "Virtual CPUs for the VM. They're shared with macOS, not reserved, so giving more is cheap when idle."
    static let memory = "Maximum RAM for the VM; all containers share it. Too low and containers get OOM-killed; too high and macOS has less to work with under load."
    static let apply = "Write the new CPU/memory to colima.yaml and restart the VM. Running containers stop."

    // System: features
    static let rosetta = "Runs x86_64 (amd64) images on Apple Silicon through Apple's Rosetta 2, which is much faster than QEMU emulation. Turn it on if you use images with no arm64 build. Changing it restarts the VM."
    static let k8s = "Runs a single-node k3s Kubernetes cluster inside the VM and adds a 'colima' kubectl context. Costs roughly 0.5 to 1 GB of RAM. Changing it restarts the VM."
    static let disk = "The VM's virtual disk, which holds images, containers, volumes and build cache. It can grow but never shrink. The file on your Mac only takes the space actually used."

    // System: disk usage
    static let dfImages = "Downloaded and built images. Reclaimable is what no container uses."
    static let dfContainers = "Containers' writable layers (files changed inside them). Reclaimable is what stopped containers hold."
    static let dfVolumes = "Named and anonymous volumes holding persistent data. Reclaimable is what no container references."
    static let dfCache = "BuildKit cache from docker build. It speeds up rebuilds; safe to clear."
    static let dfReclaimable = "Space you could free with the cleanup buttons below."
    static let pruneDangling = "Remove untagged images and the build cache. Safe; nothing in use is touched."
    static let pruneImages = "Remove all images no container uses. They'll be re-pulled when needed."
    static let pruneVolumes = "Delete all volumes no container uses. Their data is lost for good."
    static let pruneAll = "Remove stopped containers, unused networks, unused images and build cache. Volumes are kept."

    // App
    static let notify = "Get a macOS notification when a container exits with an error, is killed for running out of memory, or its healthcheck starts failing."
    static let login = "Start ColimaBar automatically when you log in."

    // Footer
    static let ssh = "Open a shell inside the Colima VM itself in iTerm."
    static let copyEnv = "Copy 'export DOCKER_HOST=…' for tools that don't read the docker context, like some testcontainers setups."
    static let config = "Open colima.yaml, the VM's configuration file, in your text editor."
    static let log = "Open Colima's log in Console, which is useful when start or stop fails."
    static let window = "Open the dashboard in a resizable window that stays open."
    static let refresh = "Reload everything now (⌘R). It normally updates by itself."
    static let quit = "Quit ColimaBar. Colima and your containers keep running."
}
