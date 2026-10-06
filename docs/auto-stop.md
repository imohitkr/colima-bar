# Auto-stop

[Docs index](README.md)

Auto-stop is off by default. When it is on, ColimaBar stops the VM after it is idle for the time that you select. This frees the CPU and memory that the VM uses.

Auto-stop stops the VM of the selected [profile](usage.md#profiles) only.

## Turn on auto-stop

1. Open the dashboard and click the System tab. The System tab shows only while Colima runs.
2. Select **Stop Colima when idle**.
3. Select the idle time: 5, 15, 30 or 60 minutes. The default is 30 minutes.

For a different time, select **Custom** and type a number of minutes from 1 to 1440 (24 hours). Press Return or click elsewhere to apply it. Until you apply it, ColimaBar uses the old time and shows a Return symbol next to the field.

While the VM is idle, the System tab shows when the idle time started and when the VM will stop.

## What counts as activity

The VM is idle when both of these are true:

- No container runs.
- No docker build, pull, push, image load, image save or commit runs through the ColimaBar socket.

Idle pollers and event streams do not count as activity. A docker client that connects to the Colima socket directly does not count either.

Before ColimaBar stops the VM, it gets a new container list to confirm that no container runs. If it cannot get the list, it does not stop the VM.

## After auto-stop

If [auto-start](auto-start.md) is on, the next docker command starts the VM again.
