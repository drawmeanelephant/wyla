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

Inspect the database read-only (`sqlite3` ships with macOS):

```sh
sqlite3 -readonly ~/Library/Application\ Support/io.github.drawmeanelephant.wyla/wyla.sqlite \
  'SELECT count(*) FROM raw_events; SELECT * FROM coverage ORDER BY id DESC LIMIT 3;'
```

The last `coverage` row's `last_heartbeat_us` should be less than 30 s old while the agent runs. Don't open the database for writing: `raw_events` rejects changes, and editing other tables can break the links that the integrity check relies on.

Check the hash chain with the agent's verifier. It prints `OK` with the row count and chain head, or `BROKEN` with the first bad row, and exits with status 1 when the chain is broken:

```sh
/Applications/Wyla.app/Contents/MacOS/WylaAgent --verify
```

Every 30 s the agent logs a heartbeat line with the longest delay of a live log line, the count of late inputs (stored but not applied, see `docs/SPEC.md`, "Collector"), and the count of TCC lines it could not parse. Late inputs that keep growing, or a delay of more than a second, point to a problem with `log stream`.

### Live collector check

`IntegrationTests/live-sessions.sh build/DerivedData/Build/Products/Debug/Wyla.app` runs the agent against real sensor use, with a temporary database: two Photo Booth camera sessions of about 10 s, with the agent killed mid-session each time, and a `screencapture -x` screenshot. It checks the recorded activations, the coverage rows, and the hash chain. It needs a camera and Photo Booth's camera permission, so CI doesn't run it. Run it after changing the collector. A session can fail when macOS doesn't log Control Center's attribution line; the printed log lines show whether that happened.

## Common problems

### The agent is not running

1. Open WYLA. The app registers the agent when it starts.
2. Look in System Settings > General > Login Items & Extensions. If WYLA is turned off under "Allow in the Background", turn it on.
3. Run the health check again. If `last exit code` is not zero, read the agent's log messages for the error.

### Activity is missing from the log

1. Check that the agent was running at that time. Each agent run is a row in the `coverage` table, and the viewer shows the gaps between runs (from M5).
2. A macOS update can change the system log lines that WYLA reads. Record a fresh capture with `scripts/capture-sensor-logs.sh` while you use each sensor, compare it with the fixtures and `docs/SPEC.md` ("Findings from the M0 spike"), and open a "Log format change" issue. Scrub personal data from anything you attach.

### The build or a check fails

Run `make check` and read the first failure. Build logs are in `build/xcodebuild*.log`. `make clean` removes all build output and the generated project, and `make bootstrap` reinstalls the pinned tools.

## Roll back

Releases are zipped app bundles on the GitHub releases page. To roll back, quit WYLA, replace `Wyla.app` with the bundle from an earlier release, and open it. A database written by a newer version can need a migration that an older version does not have. Before you roll back across an M3 or later schema change, export the log first.
