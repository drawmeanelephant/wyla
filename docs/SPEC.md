# WYLA spec

WYLA ("What You Lookin At") keeps an auditable, local log of every app that uses the camera, microphone, or screen recording on a Mac: when, for how long, and how many times.

## Decisions

| Topic | Decision |
|---|---|
| Sensors | Camera, microphone, and screen recording. |
| "Requests" | v1 counts activations (an app turning a sensor on). Permission-check totals from TCC come in M6. |
| Distribution | The owner's Mac only, with development signing. Developer ID signing and notarization come later if WYLA is shared. |
| Alerts | Notify on the first use of each sensor by each app, and on any camera or microphone use that has no attributed app. |
| Process model | A background launchd agent collects events. A SwiftUI menu bar app shows them. Both use one SQLite database. |
| Platform | macOS 26.0 deployment target, Swift 6, SwiftUI, XcodeGen. Verified on macOS 27.3. |

## Findings from the first probe (macOS 27.3, build 26C5035r)

- Control Center writes `com.apple.controlcenter` / `sensor-indicators` log lines whenever the privacy indicator changes, for example `Active activity attributions changed to ["scr:com.electron.factory"]`.
  - Bundle IDs are public. Display names and paths are `<private>`.
  - Command-line clients appear by executable name (`scr:bash`).
- The attribution set can flap: a screen-capture attribution appeared and cleared within 15 ms.
- `log stream --style ndjson` works from an admin account without root.
- The system keeps about 25 hours of these lines. Anything older is gone unless WYLA records it.
- TCC permission checks are high volume: 936 `kTCCServiceScreenCapture` checks in 15 minutes, mostly sent by `replayd` on behalf of an app.
- The retained window had no camera use, so the `cam:` and `mic:` formats are unconfirmed.

## Architecture

```
Wyla.app (SwiftUI: menu bar + window) ── reads ──▶ SQLite (WAL) ◀── writes ── WylaAgent (launchd, KeepAlive)
                                                                               ├─ log stream: Control Center indicators
                                                                               ├─ log stream --info: TCC permission requests
                                                                               ├─ CoreMediaIO listener (camera hardware on/off)
                                                                               └─ CoreAudio listener (mic hardware on/off)
WylaCore (Swift package): models, parsers, session builder, store, hash chain
```

- The agent is embedded in `Wyla.app/Contents/MacOS/WylaAgent` and registered with `SMAppService.agent(plistName:)`. launchd restarts it if it crashes.
- The agent posts a Darwin notification after each write so the app refreshes.
- WYLA is not sandboxed, because the sandbox blocks reading the system log. It makes no network connections.

## Data sources

| Source | What it gives | Attribution | Notes |
|---|---|---|---|
| Control Center `sensor-indicators` log | Start and stop per sensor per app | Bundle ID or executable name | Main source. Undocumented format that can change with macOS updates. |
| CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere` | Camera hardware on/off, device name | None | Public API, used as a cross-check |
| CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` | Microphone hardware on/off, device name | None | Public API, used as a cross-check |
| TCC `com.apple.TCC:access` log (info level) | Permission requests and allow/deny results | Through `AUTHREQ_ATTRIBUTION` | High volume, stored as per-minute totals (M6) |
| TCC.db (optional) | Which apps hold each permission, and when it changed | Bundle ID | Requires Full Disk Access (M6) |

## Session rules

- Each attribution set is compared with the previous one. A new (sensor, client) pair starts a session, and a missing pair ends it.
- Every raw activation is stored. The UI merges activations by the same app on the same sensor that are less than the merge window apart (default 2 s) into one session, and shows both counts.
- If camera or microphone hardware turns on and no matching attribution arrives within 3 s, WYLA records an unattributed session and flags it.
- When the agent starts, it closes sessions left open. If the stop is still in the system log, backfill finds it. Otherwise the session ends at the last heartbeat with `end_reason = agent_restart`.

## Data model (SQLite through GRDB)

- `raw_events`: timestamp, source, parsed fields, raw message, dedup key, `prev_hash`, `hash`. Rows can only be added.
- `sessions`: sensor, client (bundle ID or executable name), device, start, end, duration, `end_reason` (`stopped`, `agent_restart`, `inferred`), attributed flag, links to the start and stop events.
- `apps`: client ID, name, path, signing Team ID, first seen, last seen.
- `tcc_requests_agg`: one-minute bucket, client, service, result, count.
- `coverage`: agent heartbeats and backfill checkpoints.

## Audit guarantees

- Every session links to the raw log lines that created it.
- Database triggers reject UPDATE and DELETE on `raw_events`.
- Each `raw_events` row's SHA-256 hash covers the previous row's hash. "Verify integrity" recomputes the chain and reports the first bad row.
- The agent writes a heartbeat every 30 s. After a restart it backfills from its last checkpoint with `log show --start`, which covers gaps of up to about a day. Longer gaps appear in the UI as "not monitoring from X to Y".
- Limit: this detects edits and gaps. It can't stop an admin from rewriting the whole database. An optional daily export of the latest chain hash makes such a rewrite detectable.

## UI

- Menu bar: which sensors are on right now and by which app, plus today's counts.
- Timeline: a session table with filters for sensor, app, date range, and search.
- Apps: per-app counts per sensor, total time, first and last use, and a chart over time.
- Session detail: the raw log lines behind the session.
- Requests: permission request totals from TCC (M6).
- Health: collector status, unparsed-line counts, coverage gaps, integrity check.
- Export: CSV and JSON with hashes.
- Settings: merge window, retention, notifications, launch at login.

## Milestones

Tracked as GitHub milestones, with one issue each.

| # | Work | Done when |
|---|---|---|
| M0 | Spike: capture real log samples, confirm the open questions below | Fixtures committed and every open question answered |
| M1 | Repo scaffold: XcodeGen project, app, agent, and core targets, CI, GitHub setup | `make check` passes locally and in CI |
| M2 | Parsers and session builder | Fixture tests cover every M0 scenario |
| M3 | Storage, append-only log, hash chain | Edits, deletes, and inserted rows are detected; re-ingesting the same events changes nothing |
| M4 | Collector agent | Photo Booth and `screencapture` produce correct sessions, including after the agent is killed mid-session |
| M5 | Viewer UI | M4 scenarios are visible and filterable; counts match SQL queries |
| M6 | Permission requests (TCC) | Totals match `log show` counts for a sample window |
| M7 | Audit features, export, alerts | An export passes the verifier, a tampered row is flagged, first-use alerts fire once per app and sensor |
| M8 | Local install and onboarding | A fresh admin account installs WYLA and logs a camera session after onboarding alone |

## Risks

- Log format changes: the Control Center format is undocumented. Fixture tests per macOS version catch this in tests. At runtime, the Health view raises an alarm when hardware is on but no attribution parses.
- `log stream` requires an admin account. Non-admin users are out of scope for v1.
- Command-line clients such as `bash` don't identify the real tool. Where TCC or `replayd` lines name the responsible process, WYLA adds it.
- Prior art: Objective-See's OverSight detects camera and microphone use from logs. Check its license before reusing any code.

## Open questions (answer in M0)

1. The exact `cam:` and `mic:` token format, and how two apps on one sensor appear.
2. Whether the CoreMediaIO and CoreAudio "running somewhere" listeners need camera or microphone permission.
3. Whether TCC `AUTHREQ_ATTRIBUTION` lines name the responsible app in clear text.
4. CPU cost of the `log stream` child processes (target: under 1% average).
5. How Continuity Camera and virtual cameras appear in each source.
