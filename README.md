# WYLA: What You Lookin At

WYLA is a macOS app that keeps an auditable, local log of every app that turns on your camera, microphone, or screen recording: when, for how long, and how often.

> **Status:** early development. Progress is tracked in the [milestones](https://github.com/drawmeanelephant/wyla/milestones).

## Why

macOS shows a menu bar indicator while an app uses the camera, microphone, or screen, but it keeps only about a day of that history and gives you no way to review it. WYLA records each activation, ties it to the app that caused it, and stores it in a tamper-evident log you can browse and export.

## How it works

- A background agent reads the same system log lines that drive the macOS privacy indicators, and cross-checks them against camera and microphone hardware state.
- Each activation becomes a session: the app, the sensor, the start and end time, and the raw log lines behind it.
- Events are stored in an append-only, hash-chained SQLite database, and gaps in monitoring are recorded too.
- A menu bar app shows what is active now, a timeline, and per-app totals.

See [docs/SPEC.md](docs/SPEC.md) for the full design.

## Requirements

- macOS 26 or later
- An admin account (reading the system log stream requires it)
- Xcode 26 or later
- Node.js, for the duplicate-code check only

## Build

```sh
make bootstrap   # install pinned XcodeGen and SwiftLint into .tools/ and enable the pre-commit hook (once)
make run         # build and open WYLA
make check       # format, lint, tests with coverage, duplicate check, analyzer, integration tests
make help        # every target
```

`Wyla.xcodeproj` is generated from `project.yml` and is not committed. Run `make generate` after adding or moving files, or `make open` to generate and open it in Xcode.

## Releases

Pushing a `v*` tag builds the app and publishes `WYLA-<version>.zip` with a SHA-256 checksum on the [releases page](https://github.com/drawmeanelephant/wyla/releases). Builds are ad-hoc signed and not notarized, so Gatekeeper blocks the first launch. Allow it in System Settings > Privacy & Security.

## Privacy

Everything stays on your Mac. WYLA makes no network connections and has no telemetry. [PRIVACY.md](PRIVACY.md) lists what WYLA records and how to delete it, and [docs/RUNBOOK.md](docs/RUNBOOK.md) covers health checks and troubleshooting.

## License

[MIT](LICENSE)
