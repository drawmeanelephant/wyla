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
- Xcode 26 or later, plus XcodeGen and SwiftLint

## Build

```sh
make bootstrap   # install XcodeGen and SwiftLint (once)
make check       # lint, test, build
make open        # generate and open Wyla.xcodeproj
```

`Wyla.xcodeproj` is generated from `project.yml` and is not committed. Run `make generate` after adding or moving files.

## Privacy

Everything stays on your Mac. WYLA makes no network connections and has no telemetry.

## License

[MIT](LICENSE)
