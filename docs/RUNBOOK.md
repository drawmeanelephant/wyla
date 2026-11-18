# Runbook

How to check that WYLA is working, and what to do when it is not. WYLA runs only on your own Mac, so every step here is local.

## Components

| Component | What it does | How it runs |
| --- | --- | --- |
| `Wyla.app` | Menu bar app and viewer window. | Started by you, or at login. |
| `WylaAgent` | Collector that records sensor use. | launchd agent `io.github.drawmeanelephant.wyla.agent`, registered by the app with `SMAppService`. launchd restarts it when it exits (`KeepAlive`). |

## Health checks

Check that the agent is loaded and running:

```sh
launchctl print gui/$(id -u)/io.github.drawmeanelephant.wyla.agent | grep -E 'state|pid|last exit'
```

`state = running` and a `pid` mean that the agent is up. A non-zero `last exit code` means that it crashed and launchd restarted it.

Read the agent's recent messages:

```sh
log show --last 1h --style compact --predicate 'subsystem == "io.github.drawmeanelephant.wyla"'
```

Stream them live while you reproduce a problem:

```sh
log stream --style compact --predicate 'subsystem == "io.github.drawmeanelephant.wyla"'
```

## Common problems

### The agent is not running

1. Open WYLA. The app registers the agent when it starts.
2. Look in System Settings > General > Login Items & Extensions. If WYLA is turned off under "Allow in the Background", turn it on.
3. Run the health check again. If `last exit code` is not zero, read the agent's log messages for the error.

### Activity is missing from the log

1. Check that the agent was running at that time. WYLA records monitoring gaps from M3, and the viewer shows them.
2. A macOS update can change the system log lines that WYLA reads. Run the collector against a fresh capture (see `docs/SPEC.md`, "Findings from the first probe") and open a "Log format change" issue with the capture.

### The build or a check fails

Run `make check` and read the first failure. Build logs are in `build/xcodebuild*.log`. `make clean` removes all build output and the generated project, and `make bootstrap` reinstalls the pinned tools.

## Roll back

Releases are zipped app bundles on the GitHub releases page. To roll back, quit WYLA, replace `Wyla.app` with the bundle from an earlier release, and open it. A database written by a newer version can need a migration that an older version does not have. Before you roll back across an M3 or later schema change, export the log first.
