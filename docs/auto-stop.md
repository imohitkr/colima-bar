# Auto-stop

[Docs index](README.md)

Auto-stop is off by default. When it is on, ColimaBar stops the VM after it is idle for the time that you select. This frees the CPU and memory that the VM uses.

Auto-stop checks each running [profile](usage.md#profiles) with the docker runtime. Each profile has its own idle time and stops on its own. The idle time setting is the same for all profiles.

## Turn on auto-stop

1. Open the dashboard and click the System tab. The System tab shows only while Colima runs.
2. Select **Stop Colima when idle**.
3. Select the idle time: 5, 15, 30 or 60 minutes. The default is 30 minutes.

For a different time, select **Custom** and type a number of minutes from 1 to 1440 (24 hours). Press Return or click elsewhere to apply it. Until you apply it, ColimaBar uses the old time and shows a Return symbol next to the field.

While the VM is idle, the System tab shows when the idle time started and when the VM will stop.

## What counts as activity

The VM of a profile is idle when all of these are true:

- No container of the profile runs.
- No docker build, pull, push, image load, image save or commit for the profile runs through ColimaBar. For the selected profile, this includes the ColimaBar socket and the [profile socket](auto-start.md#profile-sockets). For another profile, it includes the socket of that profile.
- No VM action runs for the profile, for example a start or a restart.

Idle pollers and event streams do not count as activity. A docker client that connects to the Colima socket directly does not count either.

Before ColimaBar stops the VM, it gets a new container list from the Docker daemon of the profile to confirm that no container runs. If it cannot get the list, it does not stop the VM.

The System tab shows the idle time of the selected profile only. For the other profiles, ColimaBar asks for the container list each 30 seconds. Thus another profile stops up to 30 seconds after its idle time is over.

## After auto-stop

If [auto-start](auto-start.md) is on, the next docker command starts the VM again. The ColimaBar socket starts the selected profile. A profile socket starts its own profile.
