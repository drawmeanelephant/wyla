# AGENTS.md

Instructions for coding agents and contributors working in this repository.

## Project

WYLA ("What You Lookin At") is a macOS app that keeps an auditable, local log of which apps use the camera, microphone, and screen recording. The design is in `docs/SPEC.md`. The roadmap is the GitHub milestones M0 to M8, one issue per milestone.

## Layout

- `App/`: SwiftUI menu bar app and viewer window (target `Wyla`).
- `Agent/`: background collector (target `WylaAgent`), embedded in `Wyla.app/Contents/MacOS`.
- `Support/LaunchAgents/`: launchd plist for the agent, copied into `Wyla.app/Contents/Library/LaunchAgents` and registered with `SMAppService`.
- `Packages/WylaCore/`: models, parsers, session builder, storage. Logic that can be tested without a live Mac session belongs here.
- `project.yml`: XcodeGen spec. `Wyla.xcodeproj` is generated and not committed.

## Commands

- `make bootstrap`: install XcodeGen and SwiftLint with Homebrew.
- `make generate`: regenerate `Wyla.xcodeproj`. Run it after adding, removing, or moving files.
- `make test`: run the WylaCore tests (`swift test`).
- `make build`: generate the project and build the app.
- `make lint`: SwiftLint in strict mode.
- `make check`: lint, test, and build. CI runs the same targets.

## Rules

- Swift 6 language mode with complete concurrency checking. Fix warnings instead of suppressing them.
- The deployment target is macOS 26.0 so that CI (Xcode 26 on `macos-26` runners) and local Xcode 27 build the same code.
- System log parsers are versioned by macOS release. Every format a parser accepts needs a fixture test in `Packages/WylaCore/Tests/WylaCoreTests/Fixtures/`, captured with `log show --style ndjson` and named with the macOS version and build.
- Persisted identifiers (enum raw values, table and column names) are part of the on-disk format. Changing one requires a migration.
- WYLA never makes network connections. Don't add code or dependencies that do.
- Add third-party dependencies through SwiftPM only, and only where the spec calls for them (GRDB in M3).

## Workflow

- Branch from `main`, one branch per issue, and open a pull request that closes the issue.
- CI must pass before merging. Squash-merge.
