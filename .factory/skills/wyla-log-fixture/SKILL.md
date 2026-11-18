---
name: wyla-log-fixture
description: Capture and add a macOS unified-log fixture for a WYLA log parser. Use when adding or changing a parser for camera, microphone, or screen-recording log lines, or when a macOS update changes the log format.
---

# Add a log fixture

WYLA's parsers are versioned by macOS release. Every log format that a parser accepts needs a fixture test, so that a macOS update that changes the format fails a test instead of losing records.

## Capture

The user must perform the sensor actions, so ask them to do it. A coding agent cannot turn on the camera.

1. Record the macOS version and build: `sw_vers -productVersion` and `sw_vers -buildVersion`.
2. Start a capture with the predicate that the parser reads. `docs/SPEC.md` ("Findings from the first probe" and "Data sources") lists the processes and subsystems for each sensor. Example:

   ```sh
   log stream --style ndjson --level info --predicate 'subsystem == "com.apple.controlcenter" AND category == "sensor-indicators"' > /tmp/wyla-capture.ndjson
   ```

3. Ask the user to start and stop the sensor once with a known app, for example Photo Booth (camera), Voice Memos (microphone), or QuickTime Player's New Screen Recording (screen).
4. Stop the capture with Control-C.

## Add the fixture

1. Keep only the lines the parser needs, plus a few unrelated lines from the same processes so the test also covers what the parser must ignore.
2. Remove personal data: replace the user name in paths with `user`, and remove any window titles or file names that the capture contains.
3. Save the file as `Packages/WylaCore/Tests/WylaCoreTests/Fixtures/<sensor>-<macOS version>-<build>.ndjson`, for example `camera-27.3-26C5035r.ndjson`.
4. Add a test that parses the fixture and checks the app, sensor, start, and end of each expected activation.
5. Run `make coverage` and confirm that the test passes.

If the format changed from an earlier release, keep the old fixture and its test. The parser must accept both until the spec drops support for that macOS version.
