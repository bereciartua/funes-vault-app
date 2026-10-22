#!/bin/sh
set -eu

# Checks a built FunesVault.app before it ships: both executables have each architecture asked
# for and the app's minimum macOS; funes-mcp is signed as com.funesvault.mac.mcp; everything is
# signed with the hardened runtime by the app's team and nothing carries get-task-allow; the app
# embeds its Developer ID profile and has iCloud with CloudKit Production for the iPhone's
# doorbell (ADR-0019), and funes-mcp has no iCloud; it's a Release build (no Debug-only code); Sparkle is embedded and the app knows its feed and key;
# the bundled embedding model matches the pinned checksums; the icon, LICENSE, NOTICE and the
# third-party licenses are inside; and the whole bundle verifies. Used by the release script.
#
# Usage: sh scripts/check_bundle.sh APP [ARCH...]   (default: this Mac's arch)
#   FUNES_ALLOW_NO_UPDATES=1 accepts an empty SUFeedURL or SUPublicEDKey (a rehearsal before the
#   Sparkle keys exist); a release never sets it.
app=${1:?usage: check_bundle.sh APP [ARCH...]}
shift
[ "$#" -gt 0 ] || set -- "$(uname -m)"
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
contents="$app/Contents"
plist="$contents/Info.plist"
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }
minimum=$(read_plist LSMinimumSystemVersion)
bundle_id=$(read_plist CFBundleIdentifier)
executable=$(read_plist CFBundleExecutable)

fail() { printf 'check_bundle: %s\n' "$*" >&2; exit 1; }

[ "$bundle_id" = com.funesvault.mac ] || fail "the bundle identifier is \"$bundle_id\", not com.funesvault.mac"
[ "$executable" = FunesVault ] || fail "the executable is \"$executable\", not FunesVault"
[ "$(read_plist LSUIElement)" = true ] || fail "Info.plist lacks LSUIElement"
for name in FunesVault funes-mcp; do
    file="$contents/MacOS/$name"
    [ -f "$file" ] && [ -x "$file" ] || fail "MacOS/$name is missing"
    present=$(lipo -archs "$file")
    for arch in "$@"; do
        case " $present " in *" $arch "*) ;; *) fail "$name lacks $arch (has: $present)" ;; esac
        minos=$(vtool -arch "$arch" -show-build "$file" | awk '$1 == "minos" { print $2 }')
        [ "$minos" = "$minimum" ] || fail "$name ($arch) needs macOS $minos, not $minimum"
    done
    # Debug builds honour FUNES_DATA_DIR (a development vault); a release never does.
    if grep -q FUNES_DATA_DIR "$file"; then
        fail "$name is a Debug build (it reads FUNES_DATA_DIR)"
    fi
done

details=$(codesign --display --verbose=2 "$contents/MacOS/funes-mcp" 2>&1)
printf '%s\n' "$details" | grep -qx "Identifier=$bundle_id.mcp" || fail "funes-mcp isn't signed as $bundle_id.mcp"

# Every piece of code: hardened runtime, the app's team, no get-task-allow (which lets any
# process of the user attach a debugger, and which notarization rejects).
team() { codesign --display --verbose=2 "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
app_team=$(team "$app")
sparkle="$contents/Frameworks/Sparkle.framework"
[ -f "$sparkle/Versions/B/Sparkle" ] || fail "Frameworks/Sparkle.framework is missing"
present=$(lipo -archs "$sparkle/Versions/B/Sparkle")
for arch in "$@"; do
    case " $present " in *" $arch "*) ;; *) fail "Sparkle lacks $arch (has: $present)" ;; esac
done
otool -l "$contents/MacOS/$executable" | grep -q 'path @executable_path/../Frameworks ' \
    || fail "$executable has no rpath to Contents/Frameworks"
set -- "$app" "$contents/MacOS/funes-mcp" "$sparkle" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app"
for service in "$sparkle"/Versions/B/XPCServices/*.xpc; do
    [ -e "$service" ] && set -- "$@" "$service"
done
for part in "$@"; do
    details=$(codesign --display --verbose=2 "$part" 2>&1)
    printf '%s\n' "$details" | grep -q 'flags=.*runtime' || fail "$part lacks the hardened runtime"
    [ "$(team "$part")" = "$app_team" ] || fail "$part isn't signed by the app's team ($app_team)"
    if codesign --display --entitlements - --xml "$part" 2>/dev/null | grep -q 'get-task-allow'; then
        fail "$part carries com.apple.security.get-task-allow"
    fi
done
if codesign --display --entitlements - --xml "$app" 2>/dev/null | grep -q 'disable-library-validation'; then
    fail "the app must keep library validation"
fi

# CloudKit (ADR-0019): the profile that allows it, and the container in the Production
# environment, the one the App Store iPhone app uses.
[ -s "$contents/embedded.provisionprofile" ] || fail "the app has no embedded.provisionprofile"
codesign --display --entitlements - --xml "$app" 2>/dev/null | python3 -c '
import plistlib, sys
entitlements = plistlib.loads(sys.stdin.buffer.read() or plistlib.dumps({}))
problems = []
if "iCloud.com.funesvault" not in entitlements.get("com.apple.developer.icloud-container-identifiers", []):
    problems.append("no iCloud container iCloud.com.funesvault")
if "CloudKit" not in entitlements.get("com.apple.developer.icloud-services", []):
    problems.append("no CloudKit service")
if entitlements.get("com.apple.developer.icloud-container-environment") != "Production":
    problems.append("an iCloud environment other than Production")
if entitlements.get("com.apple.application-identifier") != "JVNJ326L7B.com.funesvault.mac":
    problems.append("no application identifier JVNJ326L7B.com.funesvault.mac")
if problems:
    sys.exit("check_bundle: the app has " + ", ".join(problems))
' || exit 1
if codesign --display --entitlements - --xml "$contents/MacOS/funes-mcp" 2>/dev/null | grep -q 'icloud'; then
    fail "funes-mcp carries an iCloud entitlement"
fi

# Updates: the feed and the key Sparkle checks every update against.
for key in SUFeedURL SUPublicEDKey; do
    if [ -z "$(read_plist "$key")" ] && [ "${FUNES_ALLOW_NO_UPDATES:-0}" != 1 ]; then
        fail "Info.plist has no $key (set FUNES_ALLOW_NO_UPDATES=1 for a rehearsal without updates)"
    fi
done

# The bundled model (ADR-0016), exactly the pinned one.
fetch="$project_dir/scripts/fetch_embedding_model.sh"
model="$contents/Resources/bge-small-en-v1.5"
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
[ "$(sha "$model/bge-small-en-v1.5.mlmodelc/weights/weight.bin" 2>/dev/null)" \
    = "$(sed -n 's/^WEIGHTS_SHA256="\([0-9a-f]*\)"$/\1/p' "$fetch")" ] \
    || fail "Resources/bge-small-en-v1.5 lacks the pinned model"
[ "$(sha "$model/vocab.txt" 2>/dev/null)" = "$(sed -n 's/^vocab.txt \([0-9a-f]*\)$/\1/p' "$fetch")" ] \
    || fail "Resources/bge-small-en-v1.5 lacks the pinned vocab.txt"

# The icon, compiled by actool into Assets.car (and AppIcon.icns for older Finder paths).
[ -s "$contents/Resources/Assets.car" ] || fail "Resources/Assets.car is missing"
[ -s "$contents/Resources/AppIcon.icns" ] || fail "Resources/AppIcon.icns is missing"
[ "$(read_plist CFBundleIconName)" = AppIcon ] || fail "Info.plist has no CFBundleIconName AppIcon"

for file in LICENSE NOTICE Licenses/GRDB.swift.txt Licenses/Sparkle.txt Licenses/bge-small-en-v1.5.txt; do
    [ -s "$contents/Resources/$file" ] || fail "Resources/$file is missing"
done
codesign --verify --deep --strict "$app" || fail "the signature doesn't verify"
printf 'check_bundle: %s passed (%s)\n' "$(basename "$app")" "$(lipo -archs "$contents/MacOS/$executable")"
