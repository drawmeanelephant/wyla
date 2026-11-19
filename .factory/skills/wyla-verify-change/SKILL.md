---
name: wyla-verify-change
description: Verify a change to WYLA before opening a pull request. Use after editing Swift sources, project.yml, scripts, or workflows in this repository, or when asked to check that WYLA still builds and runs.
---

# Verify a WYLA change

Run these steps from the repository root, in order. Stop at the first failure and fix it before continuing.

1. If you added, removed, or moved files, run `make generate`.
2. Run `make format` to fix formatting, then review the diff it made.
3. Run `make check`. It runs, in order: `format-check`, `lint`, `coverage` (minimum 80% line coverage of `Packages/WylaCore/Sources`), `duplicates` (jscpd, 3% threshold), `analyze` (clean build, then SwiftLint unused-code rules), and `integration-test`. CI runs the same targets.
4. If the change affects the app's UI or its menu, drive the real app:

   ```sh
   make build
   scripts/qa-drive.sh build/DerivedData/Build/Products/Debug/Wyla.app
   ```

   The script opens the menu, opens the main window, checks its text, and quits through the menu. It needs Accessibility permission for the process that runs it. If it fails with an Accessibility error, tell the user to grant it in System Settings > Privacy & Security > Accessibility. Do not skip the step silently. When you change the window's text, update the check in `scripts/qa-drive.sh`.
5. If the change affects the collector (`Agent/`, `Recorder`, `SessionBuilder`, or the log parsers), run the live check after `make build`:

   ```sh
   IntegrationTests/live-sessions.sh build/DerivedData/Build/Products/Debug/Wyla.app
   ```

   It opens Photo Booth twice, kills the agent mid-session, and takes a screenshot, using a temporary database. It needs a camera and Photo Booth's camera permission. Read the printed indicator lines before blaming the code for a failed session: macOS sometimes doesn't log Control Center's attribution line, and the check then reports an unattributed activation.
6. If the change touches a system log parser, confirm there is a fixture test for every log format the parser accepts (see the `wyla-log-fixture` skill).

## Reading failures

- Build errors: the last 60 lines are printed. The full log is in `build/xcodebuild.log` or `build/xcodebuild-analyze.log`.
- `analyze` failures name an unused declaration or import. Delete it instead of suppressing the rule.
- Coverage failures: add tests in `Packages/WylaCore/Tests/WylaCoreTests/`. Move logic out of `App/` or `Agent/` into WylaCore if it cannot be tested where it is.
- Integration test failures print `FAIL` lines. Each one names the bundle property or runtime behavior that broke.
