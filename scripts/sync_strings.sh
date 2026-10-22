#!/bin/sh
# Updates the String Catalogs with every user-facing string (NFR-L10N-01), as the compiler
# extracted them in the last Debug builds (SWIFT_EMIT_LOC_STRINGS=YES, which scripts/test.sh
# passes):
#   - Apps/FunesMac/Localizable.xcstrings: the Mac app's, and BridgeUI's, whose
#     String(localized:) calls resolve in the app's bundle;
#   - Apps/FunesiOS, Apps/FunesShareExtension, Apps/FunesIntents and Apps/FunesNotifications: the
#     iPhone app's and each extension's own (Apps/FunesShared is compiled into the app and the
#     Intents extension). The app and the notification service extension also get FunesPhone's,
#     the approvals' words (ApprovalWording, ApprovalAlert), which resolve in their bundles.
# With CHECK=1 it leaves the catalogs alone and fails when one is out of date.
set -eu
cd "$(dirname "$0")/.."
intermediates=build/DerivedData/Build/Intermediates.noindex
# One architecture's folder of each, found by file rather than by path: Xcode versions name a
# package target's build folder differently (BridgeUI-t.build in Xcode 27).
first_dir() { find "$intermediates" -path "$1" -name "$2" 2>/dev/null | sort | head -n 1 | xargs -I{} dirname {}; }
missing() {
    echo "sync_strings: build the apps first with SWIFT_EMIT_LOC_STRINGS=YES (sh scripts/test.sh does); no $1" >&2
    echo "sync_strings: folders with .stringsdata under $intermediates:" >&2
    find "$intermediates" -name "*.stringsdata" 2>/dev/null | xargs -I{} dirname {} | sort -u >&2
    exit 1
}
status=0
# sync CATALOG FOLDER...: the catalog gets exactly the strings of every .stringsdata in the folders.
sync() {
    catalog=$1
    shift
    args=""
    for dir in "$@"; do
        for file in "$dir"/*.stringsdata; do
            case "$file" in *ExtractedAppShortcutsMetadata.stringsdata) continue ;; esac
            args="$args --stringsdata $file"
        done
    done
    target=$catalog
    if [ "${CHECK:-0}" = "1" ]; then
        # Same file name: xcstringstool takes the table name from it.
        mkdir -p "$work/$(dirname "$catalog")"
        target="$work/$catalog"
        cp "$catalog" "$target"
    fi
    # shellcheck disable=SC2086
    xcrun xcstringstool sync "$target" $args
    if [ "${CHECK:-0}" = "1" ] && ! cmp -s "$catalog" "$target"; then
        echo "sync_strings: $catalog is out of date; run sh scripts/sync_strings.sh" >&2
        status=1
    fi
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

app=$(first_dir "*/FunesVault.build/Debug/FunesMac.build/Objects-normal/*" "*.stringsdata")
bridgeui=$(first_dir "*/BridgeUI.build/Debug/*/Objects-normal/*" "ApprovalPanel.stringsdata")
[ -n "$app" ] && [ -n "$bridgeui" ] || missing "Mac app build"
sync Apps/FunesMac/Localizable.xcstrings "$app" "$bridgeui"

phone=$(first_dir "*/FunesPhone.build/Debug-iphoneos/*/Objects-normal/*" "ApprovalWording.stringsdata")
[ -n "$phone" ] || missing "FunesPhone build for iOS"
for target in FunesiOS FunesShareExtension FunesIntents FunesNotifications; do
    dir=$(first_dir "*/FunesVault.build/Debug-iphoneos/$target.build/Objects-normal/*" "*.stringsdata")
    [ -n "$dir" ] || missing "$target build"
    case "$target" in
    FunesiOS | FunesNotifications) sync "Apps/$target/Localizable.xcstrings" "$dir" "$phone" ;;
    *) sync "Apps/$target/Localizable.xcstrings" "$dir" ;;
    esac
done
exit "$status"
