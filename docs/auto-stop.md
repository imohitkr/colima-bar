# Auto-stop

[Docs index](README.md)

Auto-stop is off by default. When it is on, ColimaBar stops the VM after it is idle for the time that you select. This frees the CPU and memory that the VM uses.

Auto-stop checks each running [profile](usage.md#profiles) with the docker runtime. Each profile has its own idle time and stops on its own. The idle time setting is the same for all profiles.

## Turn on auto-stop

1. Open the dashboard and click the System tab. The System tab shows only while Colima runs.
2. Select **Stop Colima when idle**.
3. Select the idle time: 5, 15, 30 or 60 minutes. The default is 30 minutes.
4. To keep the full time on battery or in Low Power Mode, clear **Stop sooner on battery or in Low Power Mode**. See [On battery and in Low Power Mode](#on-battery-and-in-low-power-mode).

For a different time, select **Custom** and type a number of minutes from 1 to 1440 (24 hours). Press Return or click elsewhere to apply it. Until you apply it, ColimaBar uses the old time and shows a Return symbol next to the field.

While the VM is idle, the System tab shows when the idle time started and when the VM will stop. If the Mac sleeps, the stop time moves later by the sleep time.

## What counts as activity

The VM of a profile is idle when all of these are true:

- No container of the profile runs.
- No docker build, pull, push, image load, image save or commit for the profile runs through ColimaBar. For the selected profile, this includes the ColimaBar socket and the [profile socket](auto-start.md#profile-sockets). For another profile, it includes the socket of that profile.
- No VM action runs for the profile, for example a start or a restart.
- No other action that you started from ColimaBar runs for the profile. For example, a cleanup that waits for you to click **OK** counts as activity.

Idle pollers and event streams do not count as activity. A docker client that connects to the Colima socket directly does not count either.

Before ColimaBar stops the VM, it gets a new container list from the Docker daemon of the profile to confirm that no container runs. If it cannot get the list, it does not stop the VM.

The System tab shows the idle time of the selected profile only. For the other profiles, ColimaBar asks for the container list each 30 seconds. Thus another profile stops up to 30 seconds after its idle time is over, or up to about 45 seconds on battery, in Low Power Mode or when the Mac is hot.

## When the Mac sleeps

The time that the Mac sleeps does not count as idle time. The VM sleeps with the Mac, so it does no work in that time. After a long sleep, the VM does not stop at once. It stops when the idle time is over, counted without the sleep.

Sleep does not restart the idle time. If you make the Mac sleep often, auto-stop still stops the VM.

## On battery and in Low Power Mode

**Stop sooner on battery or in Low Power Mode** is on by default. It matters only when auto-stop is on. It shortens the idle time to save energy:

- On battery, an idle VM stops after 10 minutes at most.
- In Low Power Mode, an idle VM stops after 5 minutes at most. This rule also applies on battery.

A shorter time that you select stays. For example, with 5 minutes selected, the time stays 5 minutes on battery. A hot Mac does not change the time.

A change of the power state does not restart the idle time. For example, with the default 30 minutes, you unplug the charger after 4 idle minutes. The VM then stops 6 minutes later. The System tab shows the new stop time with a note, for example "Idle since 14:02; stops at 14:12 (on battery)." If you unplug after 10 or more idle minutes, the VM stops at once (after the usual check of the container list). When you plug in the charger, the stop time moves later again.

On battery, in Low Power Mode or when the Mac is hot, ColimaBar also checks the VM less often while the dashboard is closed. Auto-start is not slower.

## After auto-stop

If [auto-start](auto-start.md) is on, the next docker command starts the VM again. The ColimaBar socket starts the selected profile. A profile socket starts its own profile.
