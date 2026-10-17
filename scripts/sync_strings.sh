#!/bin/sh
# Updates Apps/FunesMac/Localizable.xcstrings with every user-facing string (NFR-L10N-01), as
# the compiler extracted them in the last Debug build (SWIFT_EMIT_LOC_STRINGS=YES, which
# scripts/test.sh passes): the app's, and BridgeUI's, whose String(localized:) calls resolve in
# the app's bundle. With CHECK=1 it leaves the catalog alone and fails when it's out of date.
set -eu
cd "$(dirname "$0")/.."
catalog=Apps/FunesMac/Localizable.xcstrings
intermediates=build/DerivedData/Build/Intermediates.noindex
app=$(ls -d "$intermediates"/FunesVault.build/Debug/FunesMac.build/Objects-normal/* 2>/dev/null | head -n 1)
bridgeui=$(ls -d "$intermediates"/BridgeUI.build/Debug/BridgeUI-t.build/Objects-normal/* 2>/dev/null | head -n 1)
if [ -z "$app" ] || [ -z "$bridgeui" ] || ! ls "$bridgeui"/ApprovalPanel.stringsdata >/dev/null 2>&1; then
    echo "sync_strings: build the app first with SWIFT_EMIT_LOC_STRINGS=YES (sh scripts/test.sh does)" >&2
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
