#!/bin/sh
# Removes the parts `make install` put down: the launchd agent registration, the running
# app and agent, and the .app in /Applications. `--delete-data` also removes the recorded
# database and settings in ~/Library/Application Support/io.github.drawmeanelephant.wyla.
# Usage: scripts/uninstall.sh [--delete-data]
set -e

LABEL="io.github.drawmeanelephant.wyla.agent"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x WylaAgent 2>/dev/null || true
osascript -e 'tell application "Wyla" to quit' 2>/dev/null || true
pkill -x Wyla 2>/dev/null || true
rm -rf /Applications/Wyla.app

if [ "${1:-}" = "--delete-data" ]; then
    rm -rf "$HOME/Library/Application Support/io.github.drawmeanelephant.wyla"
    # Saved preferences decide first-run behavior, so they go with the data.
    defaults delete io.github.drawmeanelephant.wyla 2>/dev/null || true
    echo "WYLA removed, including the recorded log."
else
    echo "WYLA removed; the recorded log was kept. Re-run with --delete-data to delete it."
fi
