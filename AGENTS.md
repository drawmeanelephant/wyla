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

Run `make help` for the full list.

- `make bootstrap`: install the pinned XcodeGen and SwiftLint into `.tools/` (checksums verified, versions in `scripts/tools.env`) and enable the pre-commit hook in `.githooks/`.
- `make generate`: regenerate `Wyla.xcodeproj`. Run it after adding, removing, or moving files.
- `make build`: generate the project and build the app. The log is in `build/xcodebuild.log`, followed by a build timing summary.
- `make run`: build and open the app.
- `make test`: run the WylaCore tests (`swift test`).
- `make coverage`: run the tests with coverage and xunit reports (`build/test-results/`). Fails below 80% line coverage of `Packages/WylaCore/Sources`.
- `make format` / `make format-check`: `swift format` with `.swift-format`.
- `make lint`: SwiftLint in strict mode.
- `make duplicates`: jscpd copy-paste detection (3% threshold, `.jscpd.json`). Needs Node.
- `make analyze`: clean build, then SwiftLint's analyzer rules for unused declarations and imports.
- `make integration-test`: check the built bundle's layout, the agent's startup, and the app's launch.
- `make qa`: build, then drive the real app through its menu and window with `scripts/qa-drive.sh`. Needs Accessibility permission for the process that runs it; not run in CI.
- `make check`: everything CI runs (`format-check lint coverage duplicates analyze integration-test`).
- `make release-zip VERSION=v0.1.0`: build Release and zip the app into `build/release/`.

## Verifying a change

Run `make check` before opening a pull request. If the change affects the UI, also run `make qa`. The `wyla-verify-change` skill in `.factory/skills/` has the full procedure, and `wyla-log-fixture` covers capturing system log fixtures.

## Environment and secrets

- No environment variables are needed to build, test, or run WYLA, so the repository has no `.env` template.
- The repository has no secrets. CI uses only the built-in `GITHUB_TOKEN`. Never commit captured logs or databases that contain personal data; scrub fixtures as the `wyla-log-fixture` skill describes.
- Log personal values (paths that contain a user name, window titles) with `privacy: .private` in `os.Logger`. See `PRIVACY.md`.

## Rules

- Swift 6 language mode with complete concurrency checking. Fix warnings instead of suppressing them.
- The deployment target is macOS 26.0 so that CI (Xcode 26 on `macos-26` runners) and local Xcode 27 build the same code.
- System log parsers are versioned by macOS release. Every format a parser accepts needs a fixture test in `Packages/WylaCore/Tests/WylaCoreTests/Fixtures/`, captured with `scripts/capture-sensor-logs.sh`, scrubbed, and named `<source>-<macOS version>-<build>.ndjson`. `FixtureTests.swift` enforces the name, the format, and the absence of home directory paths.
- Persisted identifiers (enum raw values, table and column names) are part of the on-disk format. Changing one requires a new migration in `Packages/WylaCore/Sources/WylaCore/Storage/Schema.swift`; never edit a registered migration. The hash chain format in `docs/SPEC.md` ("Audit guarantees") is on-disk format too.
- WYLA never makes network connections. Don't add code or dependencies that do.
- Add third-party dependencies through SwiftPM only, and only where the spec calls for them (GRDB in M3).

## Workflow

- Branch from `main`, one branch per issue, and open a pull request that closes the issue.
- CI ("Lint, test, build") must pass before merging; `main` is protected and accepts changes only through pull requests. Squash-merge.
- Label pull requests (`enhancement`, `bug`, `log-format`, `audit`, `chore`) so the generated release notes sort them. Pushing a `v*` tag runs `.github/workflows/release.yml`, which publishes the zipped app with a SHA-256 checksum.
- CodeQL scans Swift and the workflows on every pull request and weekly.
- Operational checks and rollback steps are in `docs/RUNBOOK.md`.
