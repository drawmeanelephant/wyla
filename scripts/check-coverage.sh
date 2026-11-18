#!/bin/sh
# Fails when line coverage of WylaCore's Sources/ is below a minimum percentage.
# Usage: scripts/check-coverage.sh <codecov.json from swift test --show-codecov-path> <minimum>
set -eu

json=$1
minimum=$2
if [ ! -f "$json" ]; then
    echo "Coverage report not found: $json (run swift test --enable-code-coverage first)" >&2
    exit 1
fi

files='[.data[0].files[] | select(.filename | test("/Sources/"))]'
jq -r "${files}[] | \"\\(.summary.lines.percent | floor)%  \\(.filename | sub(\".*/Sources/\"; \"Sources/\"))\"" "$json"
covered=$(jq "$files | map(.summary.lines.covered) | add // 0" "$json")
total=$(jq "$files | map(.summary.lines.count) | add // 0" "$json")
if [ "$total" -eq 0 ]; then
    echo "No WylaCore source lines were measured." >&2
    exit 1
fi

percent=$(awk -v c="$covered" -v t="$total" 'BEGIN { printf "%.1f", c * 100 / t }')
summary="WylaCore line coverage: $percent% ($covered/$total lines), minimum $minimum%"
echo "$summary"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "**$summary**" >>"$GITHUB_STEP_SUMMARY"
fi

if ! awk -v p="$percent" -v m="$minimum" 'BEGIN { exit !(p + 0 >= m + 0) }'; then
    echo "Coverage is below the minimum. Add tests for the new code in WylaCore." >&2
    exit 1
fi
