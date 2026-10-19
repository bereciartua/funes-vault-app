#!/bin/sh
# Updates Apps/FunesMac/Localizable.xcstrings with every user-facing string (NFR-L10N-01), as
# the compiler extracted them in the last Debug build (SWIFT_EMIT_LOC_STRINGS=YES, which
# scripts/test.sh passes): the app's, and BridgeUI's, whose String(localized:) calls resolve in
# the app's bundle. With CHECK=1 it leaves the catalog alone and fails when it's out of date.
set -eu
cd "$(dirname "$0")/.."
catalog=Apps/FunesMac/Localizable.xcstrings
intermediates=build/DerivedData/Build/Intermediates.noindex
# One architecture's folder of each, found by file rather than by path: Xcode versions name a
# package target's build folder differently (BridgeUI-t.build in Xcode 27).
first_dir() { find "$intermediates" -path "$1" -name "$2" 2>/dev/null | sort | head -n 1 | xargs -I{} dirname {}; }
app=$(first_dir "*/FunesVault.build/Debug/FunesMac.build/Objects-normal/*" "*.stringsdata")
bridgeui=$(first_dir "*/BridgeUI.build/Debug/*/Objects-normal/*" "ApprovalPanel.stringsdata")
if [ -z "$app" ] || [ -z "$bridgeui" ]; then
    echo "sync_strings: build the app first with SWIFT_EMIT_LOC_STRINGS=YES (sh scripts/test.sh does)" >&2
    echo "sync_strings: folders with .stringsdata under $intermediates:" >&2
    find "$intermediates" -name "*.stringsdata" 2>/dev/null | xargs -I{} dirname {} | sort -u >&2
    exit 1
fi
args=""
for file in "$app"/*.stringsdata "$bridgeui"/*.stringsdata; do
    case "$file" in *ExtractedAppShortcutsMetadata.stringsdata) continue ;; esac
    args="$args --stringsdata $file"
done
target=$catalog
if [ "${CHECK:-0}" = "1" ]; then
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    target="$work/Localizable.xcstrings"
    cp "$catalog" "$target"
fi
# shellcheck disable=SC2086
xcrun xcstringstool sync "$target" $args
if [ "${CHECK:-0}" = "1" ] && ! cmp -s "$catalog" "$target"; then
    echo "sync_strings: $catalog is out of date; run sh scripts/sync_strings.sh" >&2
    exit 1
fi
