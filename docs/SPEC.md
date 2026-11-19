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

## Findings from the M0 spike (macOS 27.3, build 26C5035r)

Captured with `scripts/capture-sensor-logs.sh` while Photo Booth, Voice Memos, a ⌘⇧5 screen recording, Photo Booth plus FaceTime together, and Photo Booth on Continuity Camera each used a sensor. The scrubbed captures are the fixtures in `Packages/WylaCore/Tests/WylaCoreTests/Fixtures/`.

### Control Center indicator lines

- `Active activity attributions changed to [...]` lists every current activation as `<sensor>:<client>`, with sensor `cam`, `mic`, or `scr` and client a bundle ID or, for command-line tools, an executable name: `["cam:com.apple.PhotoBooth", "cam:com.apple.FaceTime"]`. This is the main source.
- Two apps on one camera appear as two entries. The array order is not stable (`["cam:com.apple.PhotoBooth", "scr:bash", "cam:com.apple.FaceTime"]`), so compare attribution sets, not arrays.
- When an activation ends, an Info-level line names it with its display name in clear text: `added to recent: [[cam] Photo Booth (com.apple.PhotoBooth)]`. Command-line clients have empty parentheses: `[[scr] bash ()]`. This is the only public source of display names.
- Other lines in the category (`SystemStatus attributed attribution to ...`, `Sorted active attributions from SystemStatus update: ...`, `Recent activity attributions changed to ...`, popover pause and resume) repeat the same information or are unrelated. The parser can ignore them.
- A ⌘⇧5 screen recording is attributed to `com.apple.systemuiserver`, display name "Screenshot".
- With Photo Booth and FaceTime both open, each app's attribution dropped and returned while the camera stayed on: Photo Booth had gaps of 1.9 s and 8.0 s, and FaceTime a gap of 6.8 s. The 2 s merge window joins the short gap only, so the timeline shows those as separate activations.
- A command-line client (`scr:bash`, see TCC below) produced 16 screen-capture activations in about 3 minutes, each lasting 18 to 48 ms.
- `log stream` writes a `Filtering the log data using ...` banner to stdout before the first event. The parser must skip non-JSON lines.

### Camera and microphone hardware

- A command-line process with no camera or microphone permission read `kCMIODevicePropertyDeviceIsRunningSomewhere` and `kAudioDevicePropertyDeviceIsRunningSomewhere` for every device without a prompt. TCC logged no camera check for it. `coreaudiod` preflighted microphone access for it and got authValue 1 (not granted), and the property still worked.
- Devices listed: MacBook Pro Camera, MacBook Pro Desk View Camera, MacBook Pro Microphone, and, through Continuity, iPhone Camera, iPhone Desk View Camera, and iPhone Microphone.
- The hardware state changed 66 to 344 ms after the matching attribution, on and off, measured with a 250 ms poll. The 3 s unattributed-use window has ample margin.

### TCC access lines

- `AUTHREQ_ATTRIBUTION` names the `responsible`, `accessing`, and `requesting` processes with identifier, pid, and binary path in clear text. `AUTHREQ_CTX` gives the service and `AUTHREQ_RESULT` the result, joined by `msgID`.
- This resolves command-line clients: the `scr:bash` activations came from a `VMRunner` executable whose responsible app was `com.electron.factory`, checked by `replayd` about 80 ms before each indicator change. WYLA can attribute such sessions to the responsible app.
- Binary paths can contain a user name or project names. Store them, but log them as private and scrub them from fixtures.
- Volume: 11,211 lines in 206 s across all services, including 113 screen-capture, 11 microphone, 6 audio-capture, and 3 camera requests.

### Continuity Camera

Captured separately (the `-continuity-` fixtures): Photo Booth switched from the built-in camera to iPhone Camera.

- The indicator line does not change. It stays `cam:com.apple.PhotoBooth` and names no device.
- Switching cameras ended the activation and started a new one 56 ms later. The merge window joins them.
- The hardware state shows the switch: MacBook Pro Camera turned off and iPhone Camera turned on in the same 250 ms poll. The device name for a session must come from the hardware listener.
- TCC logged a camera check for Photo Booth whose requesting process was `com.apple.cmio.ContinuityCaptureAgent`. This marks the session as Continuity Camera.

### CPU cost

Over 206 s: the indicator stream used 0.03 s of CPU (under 0.1%), the TCC Info-level stream 0.65 s (0.3% average, 1.1% peak sample), and the 4 Hz hardware poll 0.22 s (0.1%). This excludes `logd`'s own work. The listeners in M4 replace polling with property listeners.

## Architecture

```
Wyla.app (SwiftUI: menu bar + window) ── reads ──▶ SQLite (WAL) ◀── writes ── WylaAgent (launchd, KeepAlive)
                                                                               ├─ log stream --info: Control Center indicators + TCC requests
                                                                               ├─ CoreMediaIO listener (camera hardware on/off)
                                                                               └─ CoreAudio listener (mic hardware on/off)
WylaCore (Swift package): models, parsers, session builder, store, hash chain
```

- The agent is embedded in `Wyla.app/Contents/MacOS/WylaAgent` and registered with `SMAppService.agent(plistName:)` when the app starts. If macOS needs the user's approval, the menu shows that and opens Login Items settings. launchd restarts the agent if it exits.
- The agent posts the Darwin notification `io.github.drawmeanelephant.wyla.changed` after a batch of writes so the app refreshes.

### Collector

- One `log stream --style ndjson --info` process reads both log sources, with a predicate that matches the Control Center `sensor-indicators` category or the TCC `access` category. `LogRouter` sends each line to its parser. If `log stream` exits, the agent restarts it after 1 s, doubling up to 60 s, and starts over at 1 s after a run of at least 60 s.
- When `log stream` prints its banner, the agent backfills with `log show --start` from the latest checkpoint minus 10 s. Without a checkpoint it starts from the previous run's last heartbeat. Events that are already stored are skipped (see `dedup_key`).
- CoreMediaIO and CoreAudio property listeners report devices that are added or removed and devices that start or stop running. The agent rescans every 30 s in case a callback was missed. A microphone is a device with input streams and no output streams. A headset with both runs whenever it plays sound, so its running state says nothing about the microphone, and WYLA does not use it as a cross-check.
- Backfilled, live, and hardware inputs pass through a reorder buffer that holds them for 1 s and releases them in time order. The buffer is not released during a backfill. `Recorder` stores a new input that is older than one it already applied, but the input doesn't change activations. This happens when the backfill reaches back before the time the previous run began, and the agent logs the count with each regular heartbeat.
- The agent looks up each new client with Launch Services and the code signature: name, path, and Team ID. Clients without a dot are command-line executables and are marked as such.
- A lock file next to the database (`wyla.sqlite.lock`) keeps a second agent from recording into the same database. `WylaAgent --database <path>` uses another database, for tests, and `WylaAgent --verify` checks the hash chain and prints `OK` or `BROKEN`.
- WYLA is not sandboxed, because the sandbox blocks reading the system log. It makes no network connections.

## Data sources

| Source | What it gives | Attribution | Notes |
|---|---|---|---|
| Control Center `sensor-indicators` log | Start and stop per sensor per app | Bundle ID or executable name | Main source. Undocumented format that can change with macOS updates. |
| CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere` | Camera hardware on/off, device name | None | Public API, used as a cross-check |
| CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` | Microphone hardware on/off, device name | None | Public API, used as a cross-check for input-only devices |
| TCC `com.apple.TCC:access` log (info level) | Permission requests and allow/deny results | Through `AUTHREQ_ATTRIBUTION` | High volume, stored as per-minute totals (M6) |
| TCC.db (optional) | Which apps hold each permission, and when it changed | Bundle ID | Requires Full Disk Access (M6) |

## Session rules

- Each attribution set is compared with the previous one as a set, because the array order changes. A new (sensor, client) pair starts a session, and a missing pair ends it.
- Every raw activation is stored. The UI merges activations by the same app on the same sensor that are less than the merge window apart (default 2 s) into one session, and shows both counts.
- Camera or microphone hardware that runs while no attributed activation of that sensor is open is uncovered. Uncovered time becomes an unattributed activation, starting when it began, once it lasts 3 s, or at once if the hardware turns off before any attribution arrives. Uncovered time after an attributed activation that ends with the hardware turning off within 3 s is the normal shutdown lag (up to 344 ms in M0) and records nothing.
- An activation's device is the device of its sensor that ran longest during it. A merged session lists every device its activations used.
- A command-line client (an executable name, which has no dot) is linked to the responsible app of the latest TCC request for the same sensor in the 0.5 s before it started. Requests whose responsible app is already attributed are skipped.
- When the agent starts, it resumes sessions left open. If the stop is still in the system log, backfill finds it. If the last heartbeat is more than a day old, the system log no longer has the stop, so the session ends at that heartbeat, or at its start if it began after that heartbeat, with `end_reason = agent_restart`.
- Device use that the previous run didn't save before it stopped is counted again from its stored hardware events, up to its last heartbeat or the last event it stored, whichever is later. The hardware state while no agent runs is unknown and is not counted.
- `WylaCore` implements these rules: `IndicatorParser` and `TCCRequestAssembler` parse the log lines, `SessionBuilder` produces activations, `Recorder` stores them with their raw events in `EventStore`, and `SessionMerger` joins them into sessions.

## Data model (SQLite through GRDB)

The database is `~/Library/Application Support/io.github.drawmeanelephant.wyla/wyla.sqlite`, in WAL mode so that the app can read while the agent writes. The folder is mode 0700 and the database files 0600. Times are integer microseconds since 1970 (`*_us` columns), the precision of `log` timestamps. The schema is created by the migrations in `Packages/WylaCore/Sources/WylaCore/Storage/Schema.swift`.

- `raw_events`: `id`, `time_us`, `source`, `message`, `dedup_key`, `prev_hash`, `hash`. Rows can only be added. Sources:
  - `indicator`: a Control Center line as logged, including lines the parser could not read, for the Health view.
  - `hardware`: a camera or microphone device turning on or off, as `<sensor> <device> on|off`.
  - `tcc`: the TCC request that linked a command-line client to its responsible app, as JSON. Other TCC requests are not stored here (see `tcc_requests_agg`).
- `activations`: one row per activation (the timeline merges them into sessions when it reads them). Columns: `sensor`, `client` (bundle ID, executable name, or NULL when unattributed), `start_us`, `end_us` (NULL while open), `end_reason` (`stopped`, `agent_restart`), `display_name`, `device`, `device_use` (JSON seconds per device), the responsible app's identifier, pid, and path, and links to the raw events that started and ended the activation and that named its responsible app. `(sensor, client, start_us)` is unique.
- `apps`: client ID, name, path, signing Team ID, first seen, last seen, and `command_line` (1 for executable names, added by migration `v2`).
- `tcc_requests`: every completed TCC request, deduplicated on `(message_id, dedup_id)` — the log's `msgID` is `pid.counter`, reused across process restarts and reboots, so the request's identity is its CTX entry's `machTimestamp` (identical in `log stream` and `log show` even though their wall-clock times differ by ~1 ms); the request's wall time is the fallback when the entry carried none. `raw_event_id` stays NULL unless the request linked an activation to its responsible app: only linking requests join the hash chain, the rest exist here only so duplicates aren't counted twice.
- `tcc_requests_agg`: one-minute bucket, client, service, result, count (filled from M6). The client is the app TCC held responsible (`responsible`, else `accessing`, else `requesting`), so the totals name the app behind the check rather than a daemon acting on its behalf.
- `coverage`: one row per agent run, with its start, its last heartbeat, and `ended_cleanly` (added by migration `v5`): the agent sets the flag when it stops itself, so a gap after such a run is a restart, not time when WYLA was not monitoring. A gap after a run without the flag is lost monitoring — the agent crashed or the machine shut down — and shows in Health.
- `checkpoints`: per log source, the latest log timestamp the agent processed. Backfill resumes from it.
- `unparsed_lines` (migration `v5`): per log source, the count of lines the parsers rejected, maintained incrementally by the recorder for the Health view.

`Recorder` writes each input in one transaction: the raw event, then the activation changes that `SessionBuilder` derives from it. An input whose `dedup_key` is already stored is skipped before it reaches the builder, so a backfill that overlaps recorded events changes nothing. A new input older than the latest one applied is stored, but not passed to the builder, so inputs reach it in time order. After a restart, `Recorder` resumes the activations whose `end_us` is NULL.

## Audit guarantees

- Every activation links to the raw events that started and ended it.
- Database triggers reject UPDATE and DELETE on `raw_events`, and any INSERT that doesn't extend the chain (its `id` must be the next id and its `prev_hash` the last row's hash).
- Each `raw_events` row's SHA-256 hash covers the previous row's hash. Hashes are lowercase hex SHA-256 of UTF-8 text:
  - `dedup_key = sha256("<source>\n<identity>\n<message>")`. The identity of an `indicator` row is its log entry's `machTimestamp` in decimal: `log stream` and `log show` report the same entry with wall-clock times up to a few ms apart, but the same mach time, and `log stream` leaves `bootUUID` empty. The identity of other rows is `<time_us>`.
  - `hash = sha256("<id>\n<time_us>\n<source>\n<dedup_key>\n<prev_hash>\n<message>")`, with 64 zeros as the first row's `prev_hash`
- "Verify integrity" (`EventStore.verifyIntegrity`) recomputes the chain and reports the first bad row: missing ids (a deleted row), a `prev_hash` that doesn't match (an inserted or replaced row), or a hash that doesn't match (an edited row). With saved anchors it checks every one, and names the newest whose row is missing as truncation.
- `anchors.log`, one `<day> <id> <hash>` line per UTC day, saves each day's chain head next to the database. That co-location is the weak point: rewriting both the chain and this file removes the evidence, so anchors detect tampering with the database alone. Copy the file elsewhere if it needs to outlive the database. `--verify-export` also reads it for anchors inside an export's day range: an anchored row the export can't produce, up to the manifest's head, reports as truncation.
- `AuditExport.verify` checks the exported JSON only — the CSV copies carry the same columns in the same names but aren't verified. Exported ids must be contiguous apart from `skipped` rows the manifest declares: rows inside the exported span that fell outside the requested range (usually events backfilled late) are listed by id and hash only, so the chain verifies end to end without the export carrying their contents. The first row must chain to genesis or to the anchor saved for the row before it, and every anchored row the range covers — interior days always, boundary days only when the manifest covers them whole — must appear unchanged.
- The agent writes a heartbeat every 30 s, and every 5 s while an activation is open. Each heartbeat saves the checkpoints and the open activations' device use. After a restart it backfills from its last checkpoint with `log show --start`, which covers gaps of up to about a day. Longer gaps appear in the UI as "not monitoring from X to Y".
- Limit: this detects edits and gaps. It can't stop an admin from rewriting the whole chain, or from removing rows at the end. Saving the chain head (`EventStore.head()`, an id and hash) outside the database, for example in a daily export, makes such a rewrite detectable: `verifyIntegrity(anchor:)` reports when the chain no longer contains that row unchanged.

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
- Command-line clients such as `bash` don't identify the real tool. TCC `AUTHREQ_ATTRIBUTION` lines name the responsible app (confirmed in M0), so WYLA adds it.
- Prior art: Objective-See's OverSight detects camera and microphone use from logs. Check its license before reusing any code.

## Open questions

Answered in M0 (see "Findings from the M0 spike"):

1. `cam:` and `mic:` use the same `<sensor>:<client>` format as `scr:`. Two apps on one sensor appear as two entries.
2. The "running somewhere" properties need no camera or microphone permission.
3. TCC `AUTHREQ_ATTRIBUTION` lines name the responsible app in clear text.
4. Both `log stream` processes stayed under 1% average CPU.
5. Continuity Camera keeps the app's `cam:` attribution. The device comes from the hardware listener, and TCC names `ContinuityCaptureAgent`.

Not yet tested: third-party virtual cameras (for example OBS). None were installed for the spike. Check them in M4 if one is in use.
