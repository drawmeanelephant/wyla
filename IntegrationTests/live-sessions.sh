#!/bin/sh
# Live check of the collector against real sensor use (the M4 "done when" scenario). Photo Booth
# uses the camera twice for about 10 s. The agent is killed with SIGKILL mid-session both times:
# the first session is still running when the agent restarts, and the second one ends while the
# agent is down, so only the backfill can find its end. Then `screencapture -x` takes a screenshot. Uses a temporary database, never the real one.
# Needs an admin account, a camera, and Photo Booth's camera permission; not run in CI.
# Usage: IntegrationTests/live-sessions.sh <path/to/Wyla.app>
set -eu

app=${1:?usage: IntegrationTests/live-sessions.sh <path/to/Wyla.app>}
agent="$app/Contents/MacOS/WylaAgent"
work=$(mktemp -d)
database="$work/wyla.sqlite"
failures=0
pass() { printf 'ok    %s\n' "$1"; }
fail() {
    printf 'FAIL  %s\n' "$1"
    failures=$((failures + 1))
}
query() { sqlite3 -readonly "$database" "$1"; }
start_agent() {
    "$agent" --database "$database" &
    agent_pid=$!
}
trap 'kill "$agent_pid" 2>/dev/null || true; rm -rf "$work"' EXIT

started_at=$(date '+%Y-%m-%d %H:%M:%S')
start_agent
sleep 3

kill_agent() {
    kill -KILL "$agent_pid"
    wait "$agent_pid" 2>/dev/null || true
}
quit_booth() { osascript -e 'tell application "Photo Booth" to quit'; }

echo "Session 1: Photo Booth for about 10 s; the agent is killed and restarts while it runs."
open -a "Photo Booth"
sleep 5
kill_agent
sleep 2
start_agent
sleep 5
quit_booth
sleep 4

echo "Session 2: Photo Booth for about 10 s; the agent is killed and the session ends while it is down."
open -a "Photo Booth"
sleep 7
kill_agent
sleep 3
quit_booth
sleep 2
start_agent
sleep 6

echo "Taking a screenshot with screencapture -x."
screencapture -x "$work/shot.png"
sleep 4
kill -TERM "$agent_pid"
wait "$agent_pid" 2>/dev/null || true

echo
echo "Indicator lines from the system log:"
log show --start "$started_at" --style compact \
    --predicate 'subsystem == "com.apple.controlcenter" AND category == "sensor-indicators" AND eventMessage BEGINSWITH "Active activity"' |
    grep 'Active activity' || true
echo
echo "Recorded activations (sensor, client, start, end, seconds, end reason, device):"
query "SELECT sensor, ifnull(client, '-'), strftime('%H:%M:%f', start_us / 1e6, 'unixepoch', 'localtime'),
    strftime('%H:%M:%f', end_us / 1e6, 'unixepoch', 'localtime'), round((end_us - start_us) / 1e6, 2), end_reason,
    ifnull(device, '-') FROM activations ORDER BY start_us"
echo

check() { # description command...
    description=$1
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}
is() { [ "$(query "$1")" = "$2" ]; }
at_least() { [ "$(query "$1")" -ge "$2" ]; }
between() { [ "${1:-0}" -ge "$2" ] && [ "${1:-0}" -le "$3" ]; }

booth="sensor = 'camera' AND client = 'com.apple.PhotoBooth'"
check "Photo Booth has one camera activation per session, across the agent restarts" is \
    "SELECT count(*) FROM activations WHERE $booth" 2
for session in 1 2; do
    row="FROM activations WHERE $booth ORDER BY start_us LIMIT 1 OFFSET $((session - 1))"
    seconds=$(query "SELECT (end_us - start_us) / 1000000 $row")
    check "session $session ended from the log, not at a heartbeat" is "SELECT end_reason $row" stopped
    check "session $session lasted about 10 s (${seconds:-none} s)" between "$seconds" 8 20
    check "session $session links to its log lines and names its camera" is \
        "SELECT start_event_id NOT NULL AND end_event_id NOT NULL AND device NOT NULL $row" 1
done
check "all three agent runs are in coverage" is "SELECT count(*) FROM coverage" 3
check "the screenshot produced a finished screen activation" at_least \
    "SELECT count(*) FROM activations WHERE sensor = 'screen' AND end_us NOT NULL" 1
check "no unattributed activations" is "SELECT count(*) FROM activations WHERE client IS NULL" 0
check "hash chain verifies" "$agent" --database "$database" --verify
if [ "$failures" -ne 0 ]; then
    echo "$failures live check(s) failed." >&2
    exit 1
fi
echo "All live checks passed."
