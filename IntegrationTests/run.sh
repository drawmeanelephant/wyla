#!/bin/sh
# Integration checks against a built Wyla.app: the bundle layout SMAppService relies on,
# the agent's startup, and the app's launch. Usage: IntegrationTests/run.sh <path/to/Wyla.app>
set -eu

app=${1:?usage: IntegrationTests/run.sh <path/to/Wyla.app>}
app_id=io.github.drawmeanelephant.wyla
agent_label=$app_id.agent
failures=0

pass() { printf 'ok    %s\n' "$1"; }
fail() {
    printf 'FAIL  %s\n' "$1"
    failures=$((failures + 1))
}
expect_equal() { # description actual expected
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', expected '$3')"; fi
}
plist_value() { plutil -extract "$2" raw "$1" 2>/dev/null || echo "<missing>"; }

if [ ! -d "$app" ]; then
    echo "App not found at $app. Run \`make build\` first." >&2
    exit 1
fi

info="$app/Contents/Info.plist"
agent_plist="$app/Contents/Library/LaunchAgents/$agent_label.plist"

expect_equal "app bundle identifier" "$(plist_value "$info" CFBundleIdentifier)" "$app_id"
expect_equal "app runs as a menu bar app (LSUIElement)" "$(plist_value "$info" LSUIElement)" "true"
if plutil -lint "$agent_plist" >/dev/null 2>&1; then pass "launchd plist is embedded and valid"; else fail "launchd plist is embedded and valid"; fi
expect_equal "launchd Label matches the plist file name" "$(plist_value "$agent_plist" Label)" "$agent_label"
expect_equal "agent is associated with the app" "$(plist_value "$agent_plist" AssociatedBundleIdentifiers.0)" "$app_id"
expect_equal "launchd keeps the agent alive" "$(plist_value "$agent_plist" KeepAlive)" "true"
agent="$app/$(plist_value "$agent_plist" BundleProgram)"
if [ -x "$agent" ]; then pass "BundleProgram points at an executable in the bundle"; else fail "BundleProgram points at an executable in the bundle ($agent)"; fi

# The agent must keep running (launchd restarts it otherwise), log its startup, and record its
# run. It uses a temporary database so that it never touches the real one.
if [ -x "$agent" ]; then
    database_dir=$(mktemp -d)
    database="$database_dir/wyla.sqlite"
    started_at=$(date '+%Y-%m-%d %H:%M:%S')
    "$agent" --database "$database" &
    agent_pid=$!
    sleep 3
    if kill -0 "$agent_pid" 2>/dev/null; then pass "agent keeps running after launch"; else fail "agent keeps running after launch"; fi
    kill -TERM "$agent_pid" 2>/dev/null || true
    wait "$agent_pid" 2>/dev/null || true
    runs=$(sqlite3 -readonly "$database" 'SELECT count(*) FROM coverage WHERE last_heartbeat_us > started_us' 2>/dev/null || echo 0)
    expect_equal "agent records its run and a heartbeat when it stops" "$runs" "1"
    expect_equal "database is private" "$(stat -f '%Lp' "$database" 2>/dev/null)" "600"
    rm -rf "$database_dir"
    if log show --start "$started_at" --style compact \
        --predicate "subsystem == \"$app_id\" AND category == \"agent\"" | grep -q "WylaAgent started"; then
        pass "agent logs its startup message"
    else
        fail "agent logs its startup message"
    fi
fi

# The app must launch and stay up as a menu bar app.
open -n "$app" --args -WylaSkipAgentRegistration YES
app_pid=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    app_pid=$(pgrep -n -x Wyla || true)
    [ -n "$app_pid" ] && break
    sleep 1
done
if [ -n "$app_pid" ]; then
    sleep 2
    if kill -0 "$app_pid" 2>/dev/null; then pass "app launches and keeps running"; else fail "app launches and keeps running"; fi
    kill "$app_pid" 2>/dev/null || true
else
    fail "app launches and keeps running"
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures integration check(s) failed." >&2
    exit 1
fi
echo "All integration checks passed."
