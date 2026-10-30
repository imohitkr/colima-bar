import Foundation

/// Every explanation in one place, so wording stays consistent.
enum Help {
    // VM
    static let restart =
        "Restart the Colima VM. Running containers stop. Only containers with a restart policy start again. After a Colima or Lima upgrade, ColimaBar asks first."
    static let stopVM = "Stop the Colima VM and all its containers. This frees the CPU and memory that the VM uses."
    static let startVM =
        "Start the Colima VM with the settings in colima.yaml. After a Colima or Lima upgrade, ColimaBar asks first."
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
        "Open an interactive shell in the container, in iTerm, or in Terminal when iTerm is not installed. The shell is bash if the container has it, otherwise sh. If the container has no shell, use Debug shell in the ••• menu."
    static let ctrRestart = "Restart this container. Docker keeps its filesystem and volumes."
    static let ctrStop = "Stop this container (SIGTERM, then SIGKILL after 10s). You can start it again."
    static let ctrStart = "Start this stopped container again with its original settings."
    static let ctrRemove = "Delete this container. Its writable layer is lost. Docker keeps named volumes."
    static let more =
        "Inspect the container. Copy the name, ID, image or an exec command. Open ports. Open a debug shell. Remove the container."
    static let debugShell =
        "Open a shell in a new container (busybox by default) that shares the processes and network of this container. Use it when the container has no shell. The new container ends when you exit."
    static let debugShellDebug = "A debug run does not open a debug shell."
    static let stopAll = "Stop all running containers. ColimaBar asks first."

    // Inspect
    static let inspect =
        "Show the details of this container: image, state, environment, mounts, networks and ports."
    static let inspectDone = "Close the details and go back to the list."
    static let envHidden = "ColimaBar hides values with secret names. Click the eye to show one value."
    static let revealValue = "Show this value until you close the page."
    static let hideValue = "Hide this value again."
    static let copyValue = "Copy the value. A hidden value is copied in full."
    static let copyDigest = "Copy the full digest of the image."
    static let openFinder = "Show this folder of your Mac in Finder."
    static let vmOnlyPath = "This path is only in the VM. The VM does not share it from your Mac."
    static let openBrowser = "Open this port on localhost in your browser."
    static let copyPort = "Copy the address of this port. It is not a web port, so ColimaBar does not open it."

    // Compose projects
    static let composeMenu =
        "Open the project folder. Pull, update and recreate, start or remove the project with docker compose."
    static let openProjectFolder = "Show the folder of this Compose project in Finder."
    static let copyProjectPath = "Copy the path of the folder of this Compose project."
    static let vsCode = "Open the project folder in Visual Studio Code."
    static let composePull = "Pull the newest images of the project. Running containers do not change."
    static let composeUp =
        "Run docker compose up -d. It creates and starts containers that changed or are missing."
    static let composeDown =
        "Stop and remove the containers and networks of the project. Volumes and images stay. ColimaBar asks first."
    static let composeRemove =
        "Remove the containers and networks of the project. ColimaBar asks first. If the project has volumes, you keep or delete them."
    static let composeOutput = "Copy the last lines that docker compose printed for this project."
    static let composeNoDocker = "Install the docker CLI to use docker compose."
    static let composeMoved = "The Compose files are missing. The project folder moved or was deleted."
    static let composeDebug = "A debug run does not run docker compose."
    static let composeRunning = "docker compose runs for this project."

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
    static let volumeMenu = "Copy the name of this volume, back it up, restore a backup into it, or remove it."
    static let backupVolume =
        "Save the files of this volume to a tar archive on your Mac. Running containers can change files during the backup."
    static let restoreVolume =
        "Copy the files of a backup into this volume. If the volume has files, ColimaBar asks before it replaces them."
    static let restoreNewVolume = "Create a new volume from a backup file."
    static let backupAllVolumes = "Save each named volume to its own tar archive in a folder that you choose."
    static let volumesMore = "Restore a backup into a new volume, or back up all named volumes."
    static let transferCancel = "Stop the transfer. ColimaBar removes the incomplete file."
    static let transferDebug = "A debug run does not back up or restore volumes."
    static let transferBusy = "Another backup or restore runs now. Wait until it ends."
    static let transferNeedsVM = "The VM must run to back up or restore volumes."
    static let shrinkBlockedByTransfer = "A volume backup or restore runs. Wait until it ends."
    static let backupVolumesShrink =
        "Stop the shrink and save each named volume to its own tar archive in a folder that you choose. Then you can shrink the disk again."

    // System: resources
    static let presets =
        "Quick sizes. Light: a few small services. Standard: a typical dev stack with a database, some services and builds. Heavy: large builds, Kubernetes or many containers. Apply restarts the VM."
    static let cpu =
        "Virtual CPUs for the VM. macOS shares them with the VM and does not reserve them. Thus more CPUs cost little when the VM is idle."
    static let memory =
        "Maximum RAM for the VM. All containers share it. If it is too low, containers get OOM-killed. If it is too high, macOS has less memory under load."
    static let apply = "Write the new CPU and memory values to colima.yaml and restart the VM. Running containers stop."
    static let presetsWhenStopped =
        "Quick sizes. Light: a few small services. Standard: a typical dev stack with a database, some services and builds. Heavy: large builds, Kubernetes or many containers. A click saves the size to colima.yaml. The VM stays stopped. It applies at the next start."
    static let applyWhenStopped =
        "Write the new CPU and memory values to colima.yaml. The VM stays stopped. The new values apply at the next start."

    // System: features
    static let rosetta =
        "Run x86_64 (amd64) images on Apple silicon with Apple's Rosetta 2. It is much faster than QEMU emulation. Turn it on for images with no arm64 build. A change restarts the VM."
    static let k8s =
        "Run a single-node k3s Kubernetes cluster in the VM and add a kubectl context: 'colima', or 'colima-PROFILE' for other profiles. It uses about 0.5 to 1 GB of RAM. A change restarts the VM."
    static let disk =
        "The virtual disk of the VM. It holds images, containers, volumes and build cache. It grows in place and keeps your data. The file on your Mac uses only the space that the VM uses."
    static let diskShrink =
        "Make the disk smaller. A disk cannot shrink in place, so this deletes the VM and all its containers, images, volumes and build cache. Then the VM starts again with an empty disk and the same settings. You must type the profile name to confirm."
    static let rosettaWhenStopped =
        "Run x86_64 (amd64) images on Apple silicon with Apple's Rosetta 2. It is much faster than QEMU emulation. Turn it on for images with no arm64 build. A change saves to colima.yaml at once. It applies at the next start."
    static let k8sWhenStopped =
        "Run a single-node k3s Kubernetes cluster in the VM and add a kubectl context: 'colima', or 'colima-PROFILE' for other profiles. It uses about 0.5 to 1 GB of RAM. A change saves to colima.yaml at once. It applies at the next start."
    static let diskWhenStopped =
        "The virtual disk of the VM. It holds images, containers, volumes and build cache. ColimaBar saves a bigger size to colima.yaml. Colima grows the disk at the next start. Your data stays. ColimaBar asks first."
    static let diskShrinkWhenStopped =
        "Make the disk smaller. A disk cannot shrink in place, so this deletes the VM and all its containers, images, volumes and build cache. Colima starts the VM once to create the new disk, then stops it again. You must type the profile name to confirm."
    static let rosettaNeedsVZ =
        "Rosetta needs the vz VM type. This profile uses a different VM type (vmType in colima.yaml). If Rosetta is on, you can still turn it off."

    // System: advanced VM settings
    static let vmSettingsOpen = "Change DNS, the port forwarder, the IP address, mounts and registries of this VM."
    static let vmSettingsDone =
        "Close the VM settings and go back to the dashboard. ColimaBar keeps your edits until you apply or revert them."
    static let dnsServers =
        "The DNS servers that the VM uses. Use them when names do not resolve, for example with a VPN. Use up to 3 IP addresses, separated by commas. Empty uses the DNS of your Mac."
    static let vmAddress =
        "Give the VM an IP address that your Mac can reach. It needs the vz VM type. Colima cannot turn it off later."
    static let vmCopyIP = "Copy the IP address of the VM."
    static let portForwarder =
        "How Colima forwards published ports to your Mac. ssh is stable and forwards TCP only. grpc also forwards UDP."
    static let mounts = "The Mac folders that containers can use. Writable lets containers change the files."
    static let mountAdd = "Pick a Mac folder that containers can use."
    static let mountWritable = "Let containers change the files in this folder."
    static let mountRemove = "Remove this folder from the list. Containers can no longer use it."
    static let mountInotify =
        "Send file changes on the Mac to the containers, for tools that watch files. It is experimental."
    static let registryMirrors = "Registries that Docker tries before Docker Hub. Separate them with commas."
    static let insecureRegistries =
        "Registries that Docker reaches without TLS. Use them only on networks that you trust. Separate them with commas."
    static let vmTypeSection =
        "The virtual machine (vz or qemu) and how Mac folders reach it (virtiofs, sshfs or 9p). Colima fixes both when it creates the VM."
    static let vmTypePicker =
        "vz uses Apple's Virtualization framework. It is fast and supports Rosetta. qemu needs QEMU from Homebrew and is slower."
    static let mountTypePicker =
        "virtiofs is the fastest and needs vz. sshfs works with both VM types and with some tools that fail on virtiofs. 9p needs qemu."
    static let vmRecreate =
        "Delete the VM and create it again with the new types. ColimaBar can back up the volumes and save the images first. You must type the profile name to confirm."
    static let recreateBusy = "A VM type change runs now. Wait until it ends."
    static let recreatePending =
        "A VM type change did not finish. Click Restore Backups, or Dismiss, in the System tab first."
    static let recreateDirty = "Apply or discard your other edits first."
    static let recreateNoConfig = "This profile has no colima.yaml. Start it once to create one."
    static let recreateCancel =
        "Stop this step. Nothing in the VM has changed yet, or the backups stay for a later restore."
    static let recreateNoCancel = "ColimaBar cannot stop this step. Wait until it ends."
    static let recreateRestore =
        "Copy the backups into the new VM. ColimaBar restores only the volumes and images that are missing."
    static let recreateShowFolder = "Show the backup folder in Finder."
    static let recreateDismiss = "Hide this notice. The backup folder stays."
    static let newProfileVMType = vmTypePicker
    static let newProfileMountType = mountTypePicker
    static let vmSettingsApply =
        "Write the new settings to colima.yaml and restart the VM. ColimaBar keeps a copy of the old file. Running containers stop."
    static let vmSettingsApplyWhenStopped =
        "Write the new settings to colima.yaml. The VM stays stopped. The new settings apply at the next start."
    static let vmSettingsRevert = "Discard your changes."

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

    // System: cleanup
    static let cleanupOpen =
        "Show the largest images, volumes, containers, build cache and logs. Remove items one by one, and return free space to the Mac."
    static let cleanupDone = "Close the cleanup page and go back to the System tab."
    static let cleanupRefresh = "Read the disk use, the log sizes and the size of the disk image again."
    static let cleanupDiskImage =
        "The space that the VM disk uses on your Mac. When you remove items, the space is free in the VM. The disk image gets smaller only after Return Free Space."
    static let cleanupTrim =
        "Tell the VM to trim its file systems (fstrim). Then macOS can take back the free blocks of the disk image. Containers continue to run. It needs a running VM and no other action."
    static let cleanupDebug = "A debug run changes nothing."
    static let cleanupImageRemove = "Remove this image. Docker pulls it again when you need it. ColimaBar asks first."
    static let cleanupImageInUse = "A container uses this image. Remove the container first."
    static let cleanupImageTags = "This image has more than one tag. Remove its tags in the Images tab."
    static let cleanupVolumeRemove = "Delete this volume. Its data is lost permanently. ColimaBar asks first."
    static let cleanupContainerRemove =
        "Remove this stopped container and the files that changed in it. ColimaBar asks first."
    static let cleanupCache =
        "BuildKit cache from docker build. Remove Unused keeps the cache that a running build uses. The next builds take longer."
    static let pruneCache =
        "Remove the build cache that no build uses. The next builds take longer."
    static let cleanupLogs =
        "The json log file of each container in the VM. Docker keeps it until you remove the container."
    static let cleanupLogEmpty =
        "Empty the log file of this container. docker logs then shows only new lines. ColimaBar asks first."
    static let scheduledPrune =
        "Once a week, remove dangling images and unused build cache of the selected profile. It runs only while the VM runs, and no action or docker traffic runs. It never starts the VM and never asks."
    static let imageUpdateCheck =
        "Once a day, ask the registries if the images of your containers have a newer version. ColimaBar asks through the Docker daemon of the VM, so it uses no sign-in of your Mac. Docker Hub limits anonymous requests, so ColimaBar makes at most 3 Docker Hub calls in one hour. It never starts the VM."
    static let imageUpdateNone = "The registries answered for every image that ColimaBar checked."
    static let imageUpdateDebug = "A debug run contacts no registry and pulls no image."
    static let imageUpdate =
        "The registry has a newer image for this tag. Pull it with Pull New Image in the ••• menu."
    static let imageUpdateInImages =
        "The registry has a newer image for this tag. Pull it with Pull latest of this tag in the ••• menu."
    static let imageRecreate =
        "Remove the container and create it again to use the new image. A restart keeps the old image. For a Compose project, use Update and Recreate."
    static let pullLatestOfTag =
        "Pull the newest image of this tag. Containers keep the old image until you create them again."
    static let pullNewImage =
        "Pull the new image of this tag. The container keeps the old image until you create it again. For a Compose project, use Update and Recreate in the menu of the project."
    static let composeUpdateRecreate =
        "Pull the new images of this project. Then run docker compose up -d. It creates again only the services whose image changed."
    static let pullAllImages = "Pull the new image of each tag that shows an update. Containers keep the old image."
    static let checkImagesNow =
        "Ask the registries now. It works once in 5 minutes. It makes at most 3 Docker Hub calls in one hour and skips an image checked in the last hour."
    static let checkImagesNowWaiting =
        "Check Now has nothing to do. ColimaBar checked each image in the last hour, or the Docker Hub budget is spent or waits after a rate limit."
    static let imageUpdatesStrip =
        "Images with a newer version in the registry. Updates of stopped containers count here but show no badge on the row."

    /// The hint of the caption under the setting: what each failure kind means.
    static func imageUpdateFailures(_ failures: [ImageUpdateStatus.Failure: Int]) -> String {
        var lines: [String] = []
        for (kind, text) in [
            (ImageUpdateStatus.Failure.signInNeeded, "need a sign-in. ColimaBar does not use a docker login."),
            (.notFound, "are not in the registry, or the tag is private."),
            (.rateLimited, "hit a rate limit. ColimaBar waits 6 hours."),
            (.unreachable, "could not reach the registry. ColimaBar tries again in 1 hour."),
            (.other, "failed for another reason."),
        ] {
            if let n = failures[kind], n > 0 { lines.append("\(n) image\(n == 1 ? "" : "s") \(text)") }
        }
        return lines.isEmpty ? imageUpdateNone : lines.joined(separator: " ")
    }

    // Profiles
    static let profile =
        "The Colima profile that this dashboard shows. Each profile is a separate VM with its own containers, images and settings. Click to switch, to start or stop a profile, or to create or delete a profile."
    static let profiles =
        "All Colima profiles. To create or delete one, use the profile menu in the header. The dashboard and its actions apply to the selected profile. Each docker profile also has its own profile socket and the docker context colimabar-NAME."

    // Auto-start / auto-stop
    static let autoStart =
        "Docker clients (terminal, IDE test runs, testcontainers) use the ColimaBar socket. While Colima is stopped, the first real docker request starts it. Turn it off to connect directly to Colima."
    static let routeContext =
        "The current docker context. The check mark means that it points to the ColimaBar socket. The docker CLI uses it when DOCKER_HOST is not set. Most GUIs also use it."
    static let dockerContextMenu =
        "Pick the docker context for the docker CLI. A pick changes only the docker CLI, not the launchd DOCKER_HOST or testcontainers. While auto-start is on, ColimaBar returns to a context that you picked after colima start. While auto-start is on, the Colima contexts are hidden: colimabar reaches the same daemon and starts Colima on demand."
    static let kubectlSwitcher =
        "Show the kubectl context and namespace in the right-click menu and under the Kubernetes switch. ColimaBar changes them only after a click, with kubectl config. It uses ~/.kube/config, or the file that KUBECONFIG names for apps."
    static let kubeContext =
        "The current kubectl context and namespace. A pick runs kubectl config use-context or set-context. ColimaBar changes nothing else in the kubeconfig. ColimaBar lists namespaces only for a Colima cluster whose VM runs. For another cluster, use Other… and type the name."
    static let kubeNamespace =
        "The namespace of the current kubectl context. ColimaBar lists namespaces only for a Colima cluster whose VM runs. For another cluster, use Other… and type the name."
    static let contextDebug = "Not in a debug run."

    // Image scan
    static let imageScanSetting =
        "Show Scan for Vulnerabilities… in the image menu and Scan Image… in the container menu. ColimaBar runs Trivy or Grype on your Mac only after a click. The scanner downloads its vulnerability database from the internet."
    static let imageScanner = "The scanner for image scans. ColimaBar shows this choice because both are installed."
    static let imageScan =
        "Scan this image with Trivy (or Grype) on the Mac. ColimaBar exports the image from the running VM to a temporary file, then deletes it. The scanner downloads its vulnerability database from the internet on the first scan and updates it later."
    static let scanImage =
        "Scan the image of this container with Trivy (or Grype) on the Mac. ColimaBar exports the image from the running VM to a temporary file, then deletes it. The scanner downloads its vulnerability database from the internet on the first scan and updates it later."
    static let imageScanDebug = "Not in a debug run."
    static let scanAgain = "Scan this image again. ColimaBar exports it again and replaces the report."
    static let scanCancel = "Stop the scan. ColimaBar deletes the temporary files."
    static let scanDone = "Close the scan and go back to the list."
    static let scanStrip = "The number of findings for each severity."
    static let onlyFixable = "Show only the findings that have a fixed version."
    static let scanMore =
        "The page shows the first \(ImageScanReport.maxRows) findings, the most severe first."
    static let scanRunningBadge = "ColimaBar is scanning this image. Click to see the progress or to cancel."
    static let scanFailedBadge = "The last scan of this image failed. Click to see the reason."
    static let scanFixed = "The installed version and the version that fixes the finding."
    static let scanNoFix = "The installed version. No fixed version exists yet."
    static let scanRowMenu = "Copy the ID of the vulnerability."
    static func scanBadge(_ text: String) -> String {
        "Last scan of this image: \(text). Click to see the findings. ColimaBar keeps the result until you quit or turn the scan off."
    }
    static func scanSeverity(_ title: String) -> String { "Severity: \(title.lowercased())." }
    static let routeLaunchd =
        "Apps that you open from the Dock or Finder get DOCKER_HOST. Thus IDE test runners (GoLand, PyCharm, VS Code) use the ColimaBar socket. Restart an IDE that was already open."
    static let routeTestcontainers = "testcontainers (Java, Go, …) reads docker.host from ~/.testcontainers.properties."
    static let routeVarRun =
        "Some tools only look at /var/run/docker.sock (for example, the Python docker SDK without DOCKER_HOST). The link needs your admin password one time."
    static let linkVarRun =
        "Create /var/run/docker.sock as a symlink to the ColimaBar socket. ColimaBar asks for your admin password."
    static let autoStop =
        "Stop the VM of each running profile after it is idle for the selected time. Each profile has its own idle time. Running containers and docker builds, pulls or pushes keep a VM running. If auto-start is on, the next docker command starts it again."
    static let autoStopMinutes =
        "The time with no running containers and no docker builds, pulls or pushes before the VM stops. Time that the Mac sleeps does not count. On battery or in Low Power Mode, the VM can stop sooner."
    static let autoStopSooner =
        "On battery, stop an idle VM after 10 minutes at most. In Low Power Mode, stop it after 5 minutes at most. A shorter time that you select stays."
    static let autoStopCustom =
        "Type a number of minutes from 1 to 1440 (24 hours). Press Return or click elsewhere to apply it."
    static let hideIcon =
        "Hide the icon while Colima is stopped. ColimaBar continues to run. If auto-start is on, docker still starts Colima. To show the icon, press the dashboard shortcut or open ColimaBar from Spotlight."

    static let enableNotifications = "Open System Settings > Notifications > ColimaBar and turn on Allow Notifications."

    // App
    static let checkUpdates =
        "Ask GitHub one time each day if a newer ColimaBar release exists. ColimaBar sends one notification for a new version. Then it shows a button at the bottom of the dashboard. ColimaBar installs an update only after you click that button."
    static let uninstallConfirm =
        "ColimaBar opens a terminal window (iTerm or Terminal) and runs its uninstall script. The script removes the app, the login item and ColimaBar's docker routes. Docker clients then connect to Colima directly. If you turned on HTTPS for container domains, the script also removes the local certificate authority of ColimaBar, and macOS can ask for your password. It removes the file that ColimaBar added in /etc/resolver, which needs sudo. Colima, your containers and your images stay."
    static func version(_ v: String) -> String { "ColimaBar \(v). Click to check for a new version." }
    static func install(_ v: String) -> String {
        "ColimaBar \(v) is available. Click to download it, check it, replace this copy and restart. ColimaBar asks first."
    }
    static func brewUpdate(_ v: String) -> String {
        "ColimaBar \(v) is available. Homebrew installed this copy. Click to see the brew command that updates it."
    }
    static func updateLink(_ v: String, reason: String) -> String {
        "ColimaBar \(v) is available. ColimaBar cannot install it, because \(reason). Click to open the release page."
    }
    static let cancelUpdate =
        "Stop the update. ColimaBar deletes the download and keeps this version. After the install starts, you cannot cancel it."
    static let installConfirm =
        "ColimaBar replaces this copy and restarts. For about 2 seconds, a docker command does not start a stopped VM. Open connections, for example docker logs -f, close. Running containers continue."
    static let updateChecking =
        "ColimaBar checks the download: the size, the digest, the build attestation (if gh can run it), the signature and the version. It has not changed this copy yet. Click the cross to stop."
    static func updateWaiting(_ why: String) -> String {
        "ColimaBar waits to restart. \(why). The restart starts when this ends. Click the cross to stop."
    }
    static let updateInstalling = "ColimaBar replaces this copy and restarts now. You cannot stop it."
    static let updateInProgress =
        "ColimaBar is installing an update. Wait until it ends, or click the cross at the bottom of the dashboard to stop it."
    static let notify =
        "Send an alert when a container exits with an error, runs out of memory or fails its healthcheck. A container that keeps restarting gives one alert, not one for each restart. ColimaBar sends no alert for a stop that you or Compose ask for. An unhealthy alert waits up to 3 minutes after a start. ColimaBar ignores testcontainers containers. Failed actions always send an alert."
    static let notifyRecovery =
        "Send an alert when a container that sent an unhealthy alert is healthy again. Off by default. It works only while crash notifications are on."
    static let muteProject =
        "Click to stop the banners for this Compose project. The dashboard still lists its alerts."
    static let unmuteProject = "Send banners for this Compose project again."
    static let projectMuted =
        "Alerts for this project are muted. The dashboard still lists them. Click to send banners again."
    static let keepRemovedLogs =
        "Docker deletes a container started with --rm and its logs when it exits. With this on, ColimaBar keeps the last 500 lines of such a container in memory. If the container fails, View logs on its alert shows them for 5 minutes. It works only while crash notifications are on."
    static let savedLogs =
        "Open the last lines that ColimaBar saved before Docker removed this container. ColimaBar keeps them for 5 minutes."
    static let login =
        "Start ColimaBar when you log in. If it crashes, start it again immediately. Thus the ColimaBar socket continues to work."
    static let askBeforeLinks =
        "Apps, scripts and web pages can open colimabar:// links. With this on, ColimaBar asks before a link starts, stops or restarts a VM. Links that open the dashboard or Doctor never ask."
    static let shortcut =
        "Click, then press the keys of the new shortcut, for example ⌃⌥⌘C. The shortcut opens or closes the dashboard from any app. ColimaBar needs no extra permission for it."
    static let shortcutRecording =
        "Press the keys of the new shortcut now. To cancel, press Esc. If nothing happens, macOS or another app uses these keys."
    static let shortcutClear = "Remove the keyboard shortcut. The keys then go to other apps again."
    static let shortcutDebug = "A debug run does not record or use the keyboard shortcut."
    static let exportSettings =
        "Save the ColimaBar settings to a JSON file. Use the file to set up ColimaBar on a different Mac."
    static let importSettings =
        "Load ColimaBar settings from a JSON file. ColimaBar shows the changes before it applies them. A profile that does not exist on this Mac is skipped."

    // Doctor
    static let doctorOpen =
        "Open Doctor. It checks the docker setup, the VM, the disk space, the published ports and the DNS of this profile, and offers fixes."
    static let doctorRun =
        "Run all checks again. The checks only read. They do not start or change the VM."
    static let doctorDone = "Close Doctor and go back to the dashboard."
    static let doctorRepair =
        "Use this when the VM does not start or Colima reports it as Broken. ColimaBar removes the pid files that name another process, stops the VM by force, removes the other stale pid files and starts the VM. It asks first. Running containers stop. Disks, images and volumes stay."
    static let saveDiagnostics =
        "Save a text file about this Mac, Colima and ColimaBar. The file has no container data. Review it before you share it, because ColimaBar can miss a secret."
    static let reportIssue =
        "Save the diagnostics file, then open the bug report form with the versions filled in. Attach the file to the report."
    static let doctorDebug = "A debug run changes nothing."
    static func doctorFix(_ fix: DoctorFix) -> String {
        switch fix {
        case .useColimabar:
            "Switch the docker CLI to the colimabar context. The docker CLI then starts Colima on demand."
        case .setRoutes:
            "Set DOCKER_HOST for apps that launchd starts, and docker.host in ~/.testcontainers.properties. ColimaBar leaves a route that points to another daemon."
        case .copyLine:
            "Copy the line 'export DOCKER_HOST=…' for the ColimaBar socket. Paste it in place of the line in your shell startup file."
        case .useOsxkeychain:
            "Set credsStore to osxkeychain in the docker config file. ColimaBar saves a backup first."
        case .addPluginFolder:
            "Add /opt/homebrew/lib/docker/cli-plugins to cliPluginsExtraDirs in the docker config file. ColimaBar saves a backup first."
        case .repair:
            doctorRepair
        case .restartVM:
            networkRestart
        case .useSSHForwarder:
            "Set portForwarder: ssh in colima.yaml and restart the VM. ColimaBar asks first. Running containers stop."
        case .useMacDNS:
            "Remove the servers in network.dns from colima.yaml and restart the VM. The VM then uses the DNS of your Mac, also after a VPN change. ColimaBar asks first. Running containers stop."
        }
    }
    static func doctorCheck(_ check: DoctorCheck) -> String {
        switch check {
        case .tools: "The versions of colima, Lima and docker."
        case .upgrade:
            "Colima and Lima compared with the last good start of this profile. A new minor or major version, or an older one, can change the VM disk. Back up important volumes first."
        case .context: "The docker context that the docker CLI uses."
        case .appRoutes: "The routes for apps and testcontainers."
        case .shellHost: "DOCKER_HOST in the startup files of your shell."
        case .credentials: "The credential helper for registry logins."
        case .plugins: "The docker buildx and docker compose plugins."
        case .vmStatus: "The status of this profile in colima list."
        case .staleFiles: "Pid files of Lima and of the Colima daemon that name a process that is gone or not theirs."
        case .diskSpace: "Free space in the VM and on the Mac."
        case .portForwarding:
            "Published TCP ports of running containers. Each one must answer on the Mac, not only in the VM. The check sends no data."
        case .vmDNS:
            "The VM looks up registry-1.docker.io, and so does the Mac. A VPN or a network change can break the DNS of the VM."
        }
    }

    // Domains
    static let domains =
        "Open containers at names such as web.shop.localhost: the service and project for Compose, the container name for others. ColimaBar runs a proxy on this Mac only. It never starts the VM."
    static let domainLabels =
        "Set the label dev.colimabar.port to pick the container port. Set dev.colimabar.domains to add names, for example admin.shop.localhost@8081, or to off for no name."
    static func domainLink(_ url: String) -> String {
        "Open \(url) in your browser. The ColimaBar proxy forwards it to the container."
    }
    static func domainRestart(name: String, port: Int) -> String {
        "\(name) uses port \(port). Restart \(name) so its port \(port) works on the Mac."
    }
    static let domainMenu = "Open a service of this project at its .localhost name."
    static func domainTaken(_ name: String, by: String) -> String {
        "\(name) already points to \(by). Use the label dev.colimabar.domains to give this container another name."
    }
    static func domainPortNotPublished(_ p: Int) -> String {
        "The label dev.colimabar.port names port \(p), but the container does not publish it."
    }
    static func domainPortInvalid(_ value: String) -> String {
        "The label dev.colimabar.port is \"\(value)\", which is not a port. ColimaBar picks a web port instead, if there is one."
    }
    static func domainPortNotWeb(_ p: Int) -> String {
        "The proxy ignores port \(p) in a label: it is not a web port. ColimaBar picks a web port instead, if there is one."
    }
    static func domainNameDropped(_ entry: String) -> String {
        "The label dev.colimabar.domains has the entry \"\(entry)\", which gives no name. Use ASCII names that end in .localhost."
    }
    static func domainNameNotASCII(_ name: String) -> String {
        "The name \"\(name)\" has characters that are not ASCII. ColimaBar leaves them out. Use the label dev.colimabar.domains to set the name."
    }
    static let domainNameEmpty =
        "The name of this container has no ASCII letters or digits, so it gets no name. Use the label dev.colimabar.domains to set one."
    /// The hint for all notes of one container.
    static func domainNotes(_ notes: [DomainRoutes.Note], suffix: String) -> String {
        notes.map { note -> String in
            switch note {
            case .taken(let name, let by): domainTaken(DomainLink.host(relative: name, suffix: suffix), by: by)
            case .labelPortNotPublished(let port): domainPortNotPublished(port)
            case .labelPortInvalid(let value): domainPortInvalid(value)
            case .labelPortNotWeb(let port): domainPortNotWeb(port)
            case .nameDropped(let entry): domainNameDropped(entry)
            case .nameNotASCII(let name): domainNameNotASCII(name)
            case .nameEmpty: domainNameEmpty
            }
        }.joined(separator: " ")
    }
    static let domainsDebug = "A debug run does not start the proxy."
    static let domainsHTTPS =
        "Serve the names over HTTPS too. ColimaBar makes a certificate authority that works only for .localhost names and your custom suffix, and only for websites. macOS asks for your password to trust it. Turn this off to remove it."
    static let domainsTrustAgain =
        "Trust the certificate authority again. If it does not cover your names, ColimaBar replaces it. macOS then asks for your password twice: to remove the old one and to trust the new one."
    static let domainsReplaceCA =
        "Replace the certificate authority with one that permits only the names in use. macOS asks for your password twice: to remove the old one and to trust the new one. It needs the switch for container domains on."
    static let domainsDeleteCA =
        "Remove the old certificate authority from your login keychain. A removal did not finish. macOS asks for your password."
    static let domainSuffix =
        "Also answer for names such as web.shop.colima.internal. ColimaBar runs a small DNS server on this Mac and adds the file /etc/resolver/SUFFIX. macOS asks for an administrator password to add it and to remove it. With HTTPS on, a change or a removal also replaces the certificate authority, and macOS asks for your password twice more."
    static let domainSuffixApply =
        "Write the resolver file for this suffix. macOS asks for an administrator password. With HTTPS on, macOS also asks for your password twice to replace the certificate authority."
    static let domainSuffixRepair =
        "Pick a new port for the DNS server and write the resolver file again. macOS asks for an administrator password."
    static let domainsShowCA =
        "Show the certificate file in Finder. Node.js, Python and other tools with their own trust store need it. For Node.js, set NODE_EXTRA_CA_CERTS to its path."

    // Network notice
    static let networkPorts =
        "Published ports answer in the VM but not on the Mac. Port forwarding is broken, for example after a network change or a sleep."
    static let networkDNS =
        "The VM cannot resolve host names, but the Mac can. A VPN or a network change can cause this."
    static let networkRestart =
        "Restart the VM. Colima then forwards the ports again and the VM reads the DNS of the Mac again. Running containers stop. Only containers with a restart policy start again."
    static let networkSetDNS =
        "Open the VM settings, to change the DNS servers in network.dns. Empty uses the DNS of your Mac."
    static let networkCheckAgain =
        "Check the ports and the DNS of the VM again now. The check sends no data and does not change the VM."
    static let doctorStopped = "Open Doctor to find out why the VM does not start."

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
