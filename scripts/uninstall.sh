#!/bin/sh
# Removes the parts `make install` put down: the agent's SMAppService registration (through
# the app's own --unregister-agent flag, since launchd keeps the stale path otherwise), the
# running app and agent, and the .app in /Applications. `--delete-data` also removes the
# recorded database, anchors.log, and settings in
# ~/Library/Application Support/io.github.drawmeanelephant.wyla — including the chain anchors,
# so a deleted-data uninstall discards the tamper evidence too. Pass --yes to skip the
# confirmation (make uninstall-data passes it).
# Usage: scripts/uninstall.sh [--delete-data] [--yes]
set -eu

LABEL="io.github.drawmeanelephant.wyla.agent"
APP="/Applications/Wyla.app"
DATA="$HOME/Library/Application Support/io.github.drawmeanelephant.wyla"

DELETE_DATA=0
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --delete-data) DELETE_DATA=1 ;;
        --yes) ASSUME_YES=1 ;;
        *) echo "unknown argument: $arg" >&2; echo "usage: $0 [--delete-data] [--yes]" >&2; exit 2 ;;
    esac
done

if [ "$DELETE_DATA" = 1 ] && [ "$ASSUME_YES" != 1 ]; then
    printf 'Delete the recorded database, anchors.log, and settings in %s? [y/N] ' "$DATA"
    read -r answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) echo "aborted" >&2; exit 1 ;;
    esac
fi

osascript -e 'tell application "Wyla" to quit' 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# Unregister through the app's own bundle while it still exists; SMAppService would keep the
# registration for a deleted bundle, and a fresh install would then be stuck off.
if [ -x "$APP/Contents/MacOS/Wyla" ]; then
    # A build without --unregister-agent support opens the app and never returns, so
    # bound the wait; such an install may keep a stale registration either way.
    "$APP/Contents/MacOS/Wyla" --unregister-agent >/dev/null 2>&1 &
    unreg_pid=$!
    for _ in 1 2 3 4 5; do
        kill -0 "$unreg_pid" 2>/dev/null || break
        sleep 1
    done
    kill "$unreg_pid" 2>/dev/null || true
    wait "$unreg_pid" 2>/dev/null || true
fi
rm -rf "$APP"

if [ "$DELETE_DATA" = 1 ]; then
    rm -rf "$DATA"
    # Saved preferences decide first-run behavior, so they go with the data.
    defaults delete io.github.drawmeanelephant.wyla 2>/dev/null || true
    echo "WYLA removed, including the recorded log and its chain anchors."
else
    echo "WYLA removed; the recorded log was kept. Re-run with --delete-data to delete it."
fi
