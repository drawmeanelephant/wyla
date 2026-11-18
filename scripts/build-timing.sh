#!/bin/sh
# Prints the last "Build Timing Summary" block of an xcodebuild log written with -showBuildTimingSummary.
# Usage: scripts/build-timing.sh <xcodebuild.log>
set -eu

awk '
    /^Build Timing Summary/ { block = ""; inside = 1 }
    inside && NF { block = block $0 "\n" }
    /^\*\* BUILD / { inside = 0 }
    END { printf "%s", block }
' "$1"
