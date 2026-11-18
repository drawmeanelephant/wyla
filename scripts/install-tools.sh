#!/bin/sh
# Installs the XcodeGen and SwiftLint releases pinned in scripts/tools.env into .tools/,
# verifying each download against its SHA-256 checksum. Re-running is a no-op when the
# pinned versions are already installed.
set -eu

cd "$(dirname "$0")/.."
# shellcheck source=scripts/tools.env
. scripts/tools.env

tools_dir=.tools
mkdir -p "$tools_dir/downloads"

install_tool() {
    name=$1 version=$2 url=$3 sha256=$4 binary=$5
    marker="$tools_dir/$name/.version"
    if [ -f "$marker" ] && [ "$(cat "$marker")" = "$version" ] && [ -x "$tools_dir/$name/$binary" ]; then
        return 0
    fi
    archive="$tools_dir/downloads/$name-$version.zip"
    echo "Installing $name $version"
    curl --fail --silent --show-error --location --retry 3 --output "$archive" "$url"
    if ! echo "$sha256  $archive" | shasum -a 256 -c - >/dev/null; then
        echo "Checksum mismatch for $archive" >&2
        rm -f "$archive"
        exit 1
    fi
    rm -rf "${tools_dir:?}/$name"
    mkdir -p "$tools_dir/$name"
    unzip -q "$archive" -d "$tools_dir/$name"
    printf '%s\n' "$version" >"$marker"
}

install_tool xcodegen "$XCODEGEN_VERSION" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip" \
    "$XCODEGEN_SHA256" xcodegen/bin/xcodegen
install_tool swiftlint "$SWIFTLINT_VERSION" \
    "https://github.com/realm/SwiftLint/releases/download/$SWIFTLINT_VERSION/portable_swiftlint.zip" \
    "$SWIFTLINT_SHA256" swiftlint
