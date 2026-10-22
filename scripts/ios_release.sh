#!/bin/sh
set -eu

# Builds Funes Vault for iPhone for the App Store: the offline tests, a Release archive of the
# app with its share, App Intents and notification extensions, checks of what's in it (version,
# privacy manifests, entitlements), and, when asked, an App Store Connect export signed for
# distribution, or that export uploaded to App Store Connect for TestFlight. The Mac's
# counterpart is release.sh; the steps around it are in spec/release/app-store/README.md.
#
# Usage: sh scripts/ios_release.sh [--export | --upload] [--skip-tests] [--allow-provisioning-updates]
#
#   (no option)    Archive and check only. Signs with the development profiles already on
#                  this Mac; touches nothing in the Apple Developer account.
#   --export       Also export an .ipa for App Store Connect into dist/ios/, re-signed with an
#                  Apple Distribution certificate and App Store profiles.
#   --upload       Export and upload the build to App Store Connect (TestFlight). Needs a
#                  clean tree. Only with the maintainer's go-ahead.
#   --skip-tests   Don't run scripts/test.sh first (only for repeated rehearsals).
#   --allow-provisioning-updates
#                  Let Xcode create or renew certificates and profiles in the team's account
#                  (automatic signing). Needed the first time there's no Apple Distribution
#                  certificate or App Store profile on this Mac. It changes the account: only
#                  with the maintainer's go-ahead.
#
# Environment:
#   FUNES_IOS_BUILD         The build number (CFBundleVersion). Default: the project's
#                           CURRENT_PROJECT_VERSION. App Store Connect takes each build number
#                           once per version, so a second upload of the same version needs a
#                           higher one.
#   FUNES_ASC_KEY, FUNES_ASC_KEY_ID, FUNES_ASC_ISSUER
#                           An App Store Connect API key (.p8 path, key ID, issuer ID) for
#                           signing and uploading. Without one, Xcode uses the account signed in
#                           under Xcode ▸ Settings ▸ Accounts.

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="$project_dir/build/ios-release"
dist_dir="$project_dir/dist/ios"
archive="$build_dir/FunesVault-iOS.xcarchive"
team_id=JVNJ326L7B
bundle_id=com.funesvault.ios
extensions="FunesShareExtension:com.funesvault.ios.share FunesIntents:com.funesvault.ios.intents FunesNotifications:com.funesvault.ios.notifications"

export_ipa=0 upload=0 run_tests=1 provisioning=0
for arg in "$@"; do
    case "$arg" in
        --export) export_ipa=1 ;;
        --upload) export_ipa=1 upload=1 ;;
        --skip-tests) run_tests=0 ;;
        --allow-provisioning-updates) provisioning=1 ;;
        -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'ios_release: unknown option %s\n' "$arg" >&2; exit 2 ;;
    esac
done

fail() { printf 'ios_release: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }

project_setting() {
    sed -n "s/^[[:space:]]*$1 = \"\{0,1\}\([^\";]*\)\"\{0,1\};$/\1/p" \
        "$project_dir/FunesVault.xcodeproj/project.pbxproj" | head -n 1
}
version=$(project_setting MARKETING_VERSION)
build_number=${FUNES_IOS_BUILD:-$(project_setting CURRENT_PROJECT_VERSION)}
case "$build_number" in ''|*[!0-9]*) fail "the build number \"$build_number\" isn't a whole number" ;; esac

auth_args=""
if [ -n "${FUNES_ASC_KEY:-}" ]; then
    [ -f "$FUNES_ASC_KEY" ] && [ -n "${FUNES_ASC_KEY_ID:-}" ] \
        || fail "FUNES_ASC_KEY needs to be a .p8 file, with FUNES_ASC_KEY_ID (and FUNES_ASC_ISSUER for a team key)"
    auth_args="-authenticationKeyPath $FUNES_ASC_KEY -authenticationKeyID $FUNES_ASC_KEY_ID"
    [ -z "${FUNES_ASC_ISSUER:-}" ] || auth_args="$auth_args -authenticationKeyIssuerID $FUNES_ASC_ISSUER"
fi
provisioning_args=""
[ "$provisioning" = 0 ] || provisioning_args="-allowProvisioningUpdates"

# 1. The tree and the tests.
step "Funes Vault for iPhone $version ($build_number) at $(git -C "$project_dir" rev-parse --short HEAD)"
if [ "$upload" = 1 ]; then
    [ -z "$(git -C "$project_dir" status --porcelain)" ] \
        || fail "the working tree has uncommitted changes; an upload is built from a commit"
fi
sh "$project_dir/scripts/check_app_store_metadata.sh"
if [ "$run_tests" = 1 ]; then
    step "Running the tests"
    sh "$project_dir/scripts/test.sh"
fi

# 2. The archive. Automatic signing with the team's development profiles; the export re-signs.
step "Archiving (Release, generic iOS device)"
rm -rf "$archive"
mkdir -p "$build_dir"
# shellcheck disable=SC2086 # the argument lists are meant to split
xcodebuild -project "$project_dir/FunesVault.xcodeproj" -scheme FunesiOS -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$build_dir/DerivedData" \
    -archivePath "$archive" DEVELOPMENT_TEAM="$team_id" CURRENT_PROJECT_VERSION="$build_number" \
    $provisioning_args $auth_args -quiet archive \
    || fail "the archive failed (no signing profile? see --allow-provisioning-updates)"

# 3. What App Review and App Store Connect check, before anything is sent.
step "Checking the archive"
app="$archive/Products/Applications/FunesiOS.app"
[ -d "$app" ] || fail "no FunesiOS.app in the archive"
check_bundle() { # path, bundle id
    [ "$(plist "$1/Info.plist" CFBundleIdentifier)" = "$2" ] || fail "$1 isn't $2"
    [ "$(plist "$1/Info.plist" CFBundleShortVersionString)" = "$version" ] || fail "$2 isn't version $version"
    [ "$(plist "$1/Info.plist" CFBundleVersion)" = "$build_number" ] || fail "$2 isn't build $build_number"
    [ -f "$1/PrivacyInfo.xcprivacy" ] || fail "$2 has no PrivacyInfo.xcprivacy"
    plutil -lint -s "$1/PrivacyInfo.xcprivacy" || fail "$2's privacy manifest isn't a valid plist"
    [ "$(plist "$1/PrivacyInfo.xcprivacy" NSPrivacyTracking)" = false ] || fail "$2's privacy manifest says it tracks"
    [ "$(plist "$1/PrivacyInfo.xcprivacy" NSPrivacyCollectedDataTypes)" = "Array {
}" ] || fail "$2's privacy manifest lists collected data; the label is Data Not Collected"
    printf '  %s %s (%s), privacy manifest ok\n' "$2" "$version" "$build_number"
}
check_bundle "$app" "$bundle_id"
for pair in $extensions; do
    check_bundle "$app/PlugIns/${pair%%:*}.appex" "${pair#*:}"
done
entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)
for key in aps-environment com.apple.developer.icloud-container-identifiers com.apple.developer.usernotifications.time-sensitive \
    com.apple.security.application-groups keychain-access-groups; do
    printf '%s' "$entitlements" | grep -q "<key>$key</key>" || fail "the app isn't signed with $key"
done
printf '  entitlements ok (push, iCloud, Time Sensitive, App Group, Keychain group)\n'
if [ -z "$(plist "$app/Info.plist" ITSAppUsesNonExemptEncryption)" ]; then
    printf '  note: no ITSAppUsesNonExemptEncryption in Info.plist; App Store Connect asks about encryption for each build\n'
fi

if [ "$export_ipa" = 0 ]; then
    step "Archived: $archive"
    printf 'Next: sh scripts/ios_release.sh --export (needs an Apple Distribution certificate and App Store profiles).\n'
    exit 0
fi

# 4. Export for App Store Connect, or upload. Xcode re-signs for distribution: aps-environment
#    becomes production and CloudKit uses its Production environment.
destination=export
[ "$upload" = 0 ] || destination=upload
step "Exporting for App Store Connect ($destination)"
options="$build_dir/ExportOptions.plist"
cat > "$options" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$destination</string>
	<key>teamID</key><string>$team_id</string>
	<key>signingStyle</key><string>automatic</string>
	<key>uploadSymbols</key><true/>
	<key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF
rm -rf "$dist_dir"
mkdir -p "$dist_dir"
# shellcheck disable=SC2086
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" -exportPath "$dist_dir" \
    $provisioning_args $auth_args \
    || fail "the export failed (an Apple Distribution certificate and App Store profiles are needed; see --allow-provisioning-updates)"

if [ "$upload" = 1 ]; then
    step "Uploaded $version ($build_number) to App Store Connect"
    printf 'It shows in TestFlight once Apple has processed it (usually 5 to 30 minutes).\n'
else
    ipa=$(find "$dist_dir" -name '*.ipa' | head -n 1)
    [ -n "$ipa" ] || fail "the export made no .ipa"
    work="$build_dir/ipa"
    rm -rf "$work"
    mkdir -p "$work"
    ditto -x -k "$ipa" "$work"
    signed=$(codesign -d --entitlements - --xml "$work/Payload/FunesiOS.app" 2>/dev/null || true)
    printf '%s' "$signed" | grep -q '<key>get-task-allow</key><true/>' && fail "the export is debuggable (get-task-allow)"
    printf '%s' "$signed" | grep -q '<string>production</string>' || fail "the export's aps-environment isn't production"
    codesign -dvv "$work/Payload/FunesiOS.app" 2>&1 | grep -q "Authority=Apple Distribution: .*($team_id)" \
        || fail "the export isn't signed with team $team_id's Apple Distribution certificate"
    rm -rf "$work"
    step "Exported: $ipa"
    printf 'Upload it with sh scripts/ios_release.sh --upload, or with Transporter.\n'
fi
