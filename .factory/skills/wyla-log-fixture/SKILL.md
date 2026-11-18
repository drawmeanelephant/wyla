---
name: wyla-log-fixture
description: Capture and add a macOS unified-log fixture for a WYLA log parser. Use when adding or changing a parser for camera, microphone, or screen-recording log lines, or when a macOS update changes the log format.
---

# Add a log fixture

WYLA's parsers are versioned by macOS release. Every log format that a parser accepts needs a fixture test, so that a macOS update that changes the format fails a test instead of losing records.

## Capture

The user must perform the sensor actions, so ask them to do it. A coding agent cannot turn on the camera.

1. Record the macOS version and build: `sw_vers -productVersion` and `sw_vers -buildVersion`.
2. Start the capture in the background:

   ```sh
   scripts/capture-sensor-logs.sh 600 build/capture
   ```

   It records the Control Center indicator lines, the TCC access lines (Info level), and camera and microphone hardware state (`scripts/hwprobe.swift`) into `build/capture/`. `docs/SPEC.md` ("Data sources" and "Findings from the M0 spike") describes each source.
3. Ask the user to start and stop each sensor with a known app, waiting about 5 seconds at each step: Photo Booth (camera), Voice Memos (microphone), ⌘⇧5 "Record Entire Screen" (screen), and two camera apps at once (Photo Booth and FaceTime).
4. When the user is done, run `touch build/capture/stop`. The script writes the CPU time of each capture process to `build/capture/cpu.log`.

Other processes on the Mac also appear in the capture. Before you attribute an entry to a step, match its timestamps against the hardware log.

## Add the fixture

1. Keep the `log stream` banner line and whole event lines. Do not edit fields other than to scrub them.
2. Remove personal data. The repository is public. Replace user names and project names in paths, temporary directory names (`/var/folders/<a>/<b>/`), and random identifiers. Drop requests from third-party apps that the scenario did not use, so the fixture does not list the user's other software. Fields marked `<private>` are already redacted by macOS. TCC lines are high volume: keep a few requests of each kind.
3. Save the file as `Packages/WylaCore/Tests/WylaCoreTests/Fixtures/<source>-<macOS version>-<build>.ndjson`, for example `sensor-indicators-27.3-26C5035r.ndjson` or `tcc-access-27.3-26C5035r.ndjson`. `FixtureTests.swift` fails on a misnamed file, a line that is not JSON, or a path under `/Users/`.
4. Add a test that parses the fixture and checks the app, sensor, start, and end of each expected activation.
5. Run `make coverage` and confirm that the tests pass.

If the format changed from an earlier release, keep the old fixture and its test. The parser must accept both until the spec drops support for that macOS version.
