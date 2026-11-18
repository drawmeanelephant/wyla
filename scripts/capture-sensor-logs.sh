#!/bin/bash
# Captures the system log streams WYLA reads, plus camera and microphone hardware state, so a
# person can exercise each sensor and the output can become fixtures (see the wyla-log-fixture skill).
# Usage: scripts/capture-sensor-logs.sh [seconds] [output-dir]   (defaults: 300, build/capture)
# Stops after the given time or when <output-dir>/stop exists. Must run from an admin account.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
limit=${1:-300}
out=${2:-$repo/build/capture}
mkdir -p "$out"
rm -f "$out/stop"
swiftc -O -o "$out/hwprobe" "$repo/scripts/hwprobe.swift"

log stream --style ndjson --level info \
    --predicate 'subsystem == "com.apple.controlcenter" AND category == "sensor-indicators"' >"$out/sensor-indicators.ndjson" &
indicators=$!
log stream --style ndjson --level info \
    --predicate 'subsystem == "com.apple.TCC" AND category == "access"' >"$out/tcc-access.ndjson" &
tcc=$!
"$out/hwprobe" >"$out/hardware-probe.log" &
probe=$!
trap 'kill "$indicators" "$tcc" "$probe" 2>/dev/null || true' EXIT

echo "Capturing to $out for up to ${limit}s. Exercise the sensors now; touch $out/stop to finish early."
start=$SECONDS
while [ ! -f "$out/stop" ] && [ $((SECONDS - start)) -lt "$limit" ]; do
    sleep 1
done
# CPU time used by each capture process, for the agent's CPU budget.
ps -o pid=,etime=,cputime=,command= -p "$indicators,$tcc,$probe" >"$out/cpu.log"
echo "Done after $((SECONDS - start))s. CPU use is in $out/cpu.log. Scrub the files before committing them as fixtures."
