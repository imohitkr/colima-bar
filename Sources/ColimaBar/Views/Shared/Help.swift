import Foundation

/// Every explanation in one place, so wording stays consistent.
enum Help {
    // VM
    static let restart =
        "Restart the Colima VM. Running containers stop. Only containers with a restart policy start again."
    static let stopVM = "Stop the Colima VM and all its containers. This frees the CPU and memory that the VM uses."
    static let startVM = "Start the Colima VM with the settings in colima.yaml."
    static let subtitle =
        "The CPUs, memory and disk of the VM, its architecture, and how the VM shares your Mac files (virtiofs is the fast native option)."

    // Tiles
    static let cpuTile =
        "CPU that all running containers use together, as a share of the VM total. 100% means that all VM cores are busy."
    static let memTile =
        "Memory that all running containers use, without the reclaimable page cache (the same value that docker stats shows). The graph shows it as a share of VM memory."
    static let ctrTile = "Running and stopped containers. Unhealthy means that the HEALTHCHECK of a container fails."

    // Tabs / filter
    static let tabs =
        "Containers: what runs now. Images: what you downloaded. Volumes: persistent data. System: VM settings and cleanup."
    static let runningOnly = "Hide stopped and exited containers."
    static let search = "Filter by name, image or compose project. ⌘F moves the focus to this field."

    // Containers
    static let projectGroup =
        "Containers that docker compose started, grouped by project. The buttons act on the full project."
    static let standalone = "Containers that docker compose did not start."
    static let ctrCPU = "CPU as a percentage of one core, like docker stats. 200% means that two cores are fully busy."
    static let ctrMem = "Memory that the container uses now, without the reclaimable page cache."
    static func port(_ p: Int) -> String {
        "Open http://localhost:\(p) in your browser. The container publishes this host port."
    }
    static let healthy = "The HEALTHCHECK passes."
    static let unhealthy = "The HEALTHCHECK fails. The container runs, but it probably does not work. Check its logs."
    static let starting = "The HEALTHCHECK has not passed yet. The container is still starting."
    static let logs =
        "Open a live log window for this container, with search, follow, a stderr filter and copy. To follow the logs in a terminal window, use the ••• menu."
    static let shell =
        "Open an interactive shell in the container, in iTerm, or in Terminal when iTerm is not installed. The shell is bash if the container has it, otherwise sh."
    static let ctrRestart = "Restart this container. Docker keeps its filesystem and volumes."
    static let ctrStop = "Stop this container (SIGTERM, then SIGKILL after 10s). You can start it again."
    static let ctrStart = "Start this stopped container again with its original settings."
    static let ctrRemove = "Delete this container. Its writable layer is lost. Docker keeps named volumes."
    static let more = "Copy the name, ID, image or an exec command. Open ports. Remove the container."
    static let stopAll = "Stop all running containers. ColimaBar asks first."

    // Images
    static let inUse =
        "At least one container (running or stopped) uses this image. Thus you cannot remove or prune it."
    static let dangling =
        "Untagged layers that remain, usually after you rebuild an image with the same tag. You can safely remove them."
    static let removeDangling = "Remove untagged images and the build cache. Items in use stay."
    static let removeUnusedImages =
        "Remove all images that no container uses. Docker pulls them again when you need them."
    static let imageSize =
        "Size on disk. Images share the space of their shared base layers. Thus the total can be less than the sum."

    // Volumes
    static let anonymous =
        "An unnamed volume that Docker created for a VOLUME line in an image. Often it remains after you remove the containers."
    static let unusedVolume = "No container uses this volume. If you remove it, its data is deleted permanently."
    static let removeUnusedVolumes =
        "Delete all volumes that no container uses. Their data is lost permanently. ColimaBar asks first."

    // System: resources
    static let presets =
        "Quick sizes. Light: a few small services. Standard: a typical dev stack with a database, some services and builds. Heavy: large builds, Kubernetes or many containers. Apply restarts the VM."
    static let cpu =
        "Virtual CPUs for the VM. macOS shares them with the VM and does not reserve them. Thus more CPUs cost little when the VM is idle."
    static let memory =
        "Maximum RAM for the VM. All containers share it. If it is too low, containers get OOM-killed. If it is too high, macOS has less memory under load."
    static let apply = "Write the new CPU and memory values to colima.yaml and restart the VM. Running containers stop."

    // System: features
    static let rosetta =
        "Run x86_64 (amd64) images on Apple silicon with Apple's Rosetta 2. It is much faster than QEMU emulation. Turn it on for images with no arm64 build. A change restarts the VM."
    static let k8s =
        "Run a single-node k3s Kubernetes cluster in the VM and add a kubectl context: 'colima', or 'colima-PROFILE' for other profiles. It uses about 0.5 to 1 GB of RAM. A change restarts the VM."
    static let disk =
        "The virtual disk of the VM. It holds images, containers, volumes and build cache. It can grow but cannot shrink. The file on your Mac uses only the space that the VM uses."

    // System: disk usage
    static let dfImages = "Images that you downloaded or built. Reclaimable is the part that no container uses."
    static let dfContainers =
        "Writable layers of containers (files that changed in them). Reclaimable is the part that stopped containers hold."
    static let dfVolumes =
        "Named and anonymous volumes with persistent data. Reclaimable is the part that no container uses."
    static let dfCache = "BuildKit cache from docker build. It makes rebuilds faster. You can safely clear it."
    static let dfReclaimable = "Space that the cleanup buttons below can free."
    static let pruneDangling = "Remove untagged images and the build cache. This is safe: items in use stay."
    static let pruneImages = "Remove all images that no container uses. Docker pulls them again when you need them."
    static let pruneVolumes = "Delete all volumes that no container uses. Their data is lost permanently."
    static let pruneAll = "Remove stopped containers, unused networks, unused images and build cache. Volumes stay."

    // Profiles
    static let profile =
        "The Colima profile that this dashboard shows. Each profile is a separate VM with its own containers, images and settings. To switch, select a different profile."
    static let profiles =
        "All Colima profiles. To create one, run `colima start --profile NAME`. The dashboard and all actions apply to the selected profile."

    // Auto-start / auto-stop
    static let autoStart =
        "Docker clients (terminal, IDE test runs, testcontainers) use the ColimaBar socket. While Colima is stopped, the first real docker request starts it. Turn it off to connect directly to Colima."
    static let routeContext =
        "The current docker context points to the ColimaBar socket. The docker CLI uses it when DOCKER_HOST is not set. Most GUIs also use it."
    static let routeLaunchd =
        "Apps that you open from the Dock or Finder get DOCKER_HOST. Thus IDE test runners (GoLand, PyCharm, VS Code) use the ColimaBar socket. Restart an IDE that was already open."
    static let routeTestcontainers = "testcontainers (Java, Go, …) reads docker.host from ~/.testcontainers.properties."
    static let routeVarRun =
        "Some tools only look at /var/run/docker.sock (for example, the Python docker SDK without DOCKER_HOST). The link needs your admin password one time."
    static let linkVarRun =
        "Create /var/run/docker.sock as a symlink to the ColimaBar socket. ColimaBar asks for your admin password."
    static let autoStop =
        "Stop the VM after it is idle for the selected time. Running containers and docker builds, pulls or pushes keep it running. If auto-start is on, the next docker command starts it again."
    static let autoStopMinutes =
        "The time with no running containers and no docker builds, pulls or pushes before the VM stops."
    static let autoStopCustom =
        "Type a number of minutes from 1 to 1440 (24 hours). Press Return or click elsewhere to apply it."
    static let hideIcon =
        "Hide the icon while Colima is stopped. ColimaBar continues to run. If auto-start is on, docker still starts Colima. To show the icon, open ColimaBar from Spotlight."

    static let enableNotifications = "Open System Settings > Notifications > ColimaBar and turn on Allow Notifications."

    // App
    static let checkUpdates =
        "Ask GitHub one time each day if a newer ColimaBar release exists. ColimaBar sends one notification for a new version. Then it shows a button at the bottom of the dashboard."
    static let uninstallConfirm =
        "ColimaBar opens a terminal window (iTerm or Terminal) and runs its uninstall script. The script removes the app, the login item and ColimaBar's docker routes. Docker clients then connect to Colima directly. Colima, your containers and your images stay."
    static func version(_ v: String) -> String { "ColimaBar \(v). Click to check for a new version." }
    static func update(_ v: String) -> String {
        "ColimaBar \(v) is available. Click to open the release page and download it."
    }
    static let notify =
        "Send an alert when a container exits with an error, runs out of memory or fails its healthcheck. ColimaBar ignores testcontainers containers. Failed actions always send an alert."
    static let keepRemovedLogs =
        "Docker deletes a container started with --rm and its logs when it exits. With this on, ColimaBar keeps the last 500 lines of such a container in memory. If the container fails, View logs on its alert shows them for 5 minutes. It works only while crash notifications are on."
    static let savedLogs =
        "Open the last lines that ColimaBar saved before Docker removed this container. ColimaBar keeps them for 5 minutes."
    static let login =
        "Start ColimaBar when you log in. If it crashes, start it again immediately. Thus the ColimaBar socket continues to work."

    // Footer
    static let ssh = "Open a shell in the Colima VM, in iTerm, or in Terminal when iTerm is not installed."
    static let copyEnv =
        "Copy 'export DOCKER_HOST=…' for the ColimaBar socket, for scripts or shells that do not read the docker context. It starts Colima on demand while ColimaBar runs. After you quit ColimaBar, it still reaches Colima."
    static let config = "Open colima.yaml, the configuration file of the VM, in your text editor."
    static let log = "Open the Colima log in Console. This helps when start or stop fails."
    static let window = "Open the dashboard in a resizable window that stays open."
    static let refresh = "Reload all data now (⌘R). The dashboard usually updates automatically."
    static let quit =
        "Quit ColimaBar. Colima and your containers continue to run. Auto-start stops: docker does not start Colima until you open ColimaBar again."
}
