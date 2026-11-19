# Privacy

WYLA records which apps use your camera, microphone, and screen. That record is sensitive, so this document says what WYLA collects, where it goes, and how to remove it.

## What WYLA collects

For each time an app uses a sensor, WYLA stores:

- The app's bundle identifier, name, path, and process ID.
- The sensor (camera, microphone, or screen recording).
- The start and end time of the activation.
- The raw system log lines that WYLA used to detect the activation, so you can audit how each record was made.
- Gaps in monitoring, such as when the agent was not running.

WYLA does not record audio, video, screen contents, or keystrokes. It never reads what an app captures, only that the app turned a sensor on.

## Where the data goes

The data stays on your Mac. WYLA makes no network connections, has no telemetry or analytics, and has no crash reporter that sends data. The project's rules forbid adding code or dependencies that use the network (see `AGENTS.md`).

The database is `~/Library/Application Support/io.github.drawmeanelephant.wyla/wyla.sqlite`. The folder and the database files are readable only by your user account (modes 0700 and 0600). The agent also writes its own diagnostic messages to the macOS unified log under the subsystem `io.github.drawmeanelephant.wyla`. Those messages contain app identifiers and sensor names, and macOS removes them on its normal log schedule.

## Retention

WYLA keeps records until you delete them. The log is append-only and hash-chained so that edits are detectable, so WYLA has no option to delete single records. You can delete the whole log (see below). A retention setting is planned for the Settings view (see `docs/SPEC.md`, "UI").

## Export

From M7, the viewer exports the log as CSV or JSON, with the hash chain, so you can check or archive it elsewhere. Exported files are yours to handle. WYLA does not upload them anywhere.

## Delete everything

1. Quit WYLA from its menu bar item. This also stops the agent.
2. Delete the data folder:

   ```sh
   rm -rf ~/Library/Application\ Support/io.github.drawmeanelephant.wyla
   ```

3. To uninstall, remove `Wyla.app` as well. macOS unregisters the agent when the app is deleted. Check in System Settings > General > Login Items & Extensions that WYLA is no longer listed.

## Logs and personal data in code

Agent diagnostics use `os.Logger`. Values that can identify a person, such as file paths that contain a user name, must be logged with `privacy: .private` so that macOS redacts them in log output. Bundle identifiers and sensor names are public.
