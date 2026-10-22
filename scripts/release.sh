#!/bin/sh
set -eu

# Builds a release: the offline tests, a universal Xcode archive exported with Developer ID
# and the Developer ID provisioning profile (iCloud for the iPhone's doorbell), notarization
# and stapling, a DMG (also as FunesVault.dmg, a name that never changes) and a
# zip, SHA-256 sums, the Sparkle appcast (when a Sparkle key is given), and a draft GitHub
# release for the maintainer to review and publish. The release workflow runs it on a v* tag;
# it also runs by hand on a Mac with the identity and the notary credentials.
#
# Usage: sh scripts/release.sh [--untagged] [--no-notarize] [--no-release] [--skip-tests]
#
#   --untagged     Build the commit at HEAD even though it isn't tagged v<version>;
#                  implies --no-release. For rehearsals.
#   --no-notarize  Skip notarization and stapling. The output is signed but Gatekeeper
#                  blocks it on other Macs; for rehearsals without Apple's notary service.
#                  Implies --no-release.
#   --no-release   Build everything in dist/ but create no GitHub release.
#   --skip-tests   Don't run scripts/test.sh first (only for repeated rehearsals).
#
# Environment:
#   FUNES_SIGN_IDENTITY     The codesign identity. Default: the one "Developer ID Application"
#                           identity in the keychain.
#   FUNES_MAC_PROFILE       The name of the Developer ID provisioning profile for
#                           com.funesvault.mac with iCloud (iCloud.com.funesvault). Default:
#                           "Funes Vault Mac Developer ID". It must be installed in
#                           ~/Library/Developer/Xcode/UserData/Provisioning Profiles (Xcode ▸
#                           Settings ▸ Accounts ▸ Download Manual Profiles, or the file from the
#                           developer site); the newest valid one of that name is used.
#   FUNES_NOTARY_PROFILE    A notarytool keychain profile (by hand; on the maintainer's Mac
#                           it's "ekbridge", the same team), or
#   FUNES_NOTARY_KEY, FUNES_NOTARY_KEY_ID, FUNES_NOTARY_ISSUER
#                           an App Store Connect API key (.p8 path, key ID, issuer ID; the
#                           issuer is empty for an individual key).
#   FUNES_SPARKLE_KEY_FILE  Sparkle's EdDSA private key (from generate_keys -x) to sign the
#                           zip and write appcast.xml. Required for a release once the app has
#                           SUPublicEDKey: without an appcast, installed copies wouldn't see the
#                           release. Rehearsals may leave it out.
#   FUNES_SPARKLE_KEYCHAIN=1  Instead of a key file, sign with the key generate_keys stored in
#                           the login keychain under the account FUNES_SPARKLE_ACCOUNT
#                           (default funes-vault; EK Bridge's key is a different account).
#   FUNES_SPARKLE_BIN       Folder with Sparkle's sign_update. Default: the pinned Sparkle
#                           package's bin folder, which the archive step resolves.
#   FUNES_RELEASE_REPO      The GitHub repository. Default: GITHUB_REPOSITORY, else
#                           bereciartua/funes-vault-app.
#   GH_TOKEN                For gh in CI (the workflow passes github.token).

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dist_dir="$project_dir/dist"
build_dir="$project_dir/build/release"
# Resolved packages (BridgeKit, GRDB, Sparkle with its bin tools) outlive a release's build folder.
packages_dir="$project_dir/build/source-packages"
repo=${FUNES_RELEASE_REPO:-${GITHUB_REPOSITORY:-bereciartua/funes-vault-app}}
sparkle_account=${FUNES_SPARKLE_ACCOUNT:-funes-vault}
app_name=FunesVault
display_name="Funes Vault"
team_id=JVNJ326L7B
bundle_id=com.funesvault.mac
icloud_container=iCloud.com.funesvault
profile_name=${FUNES_MAC_PROFILE:-Funes Vault Mac Developer ID}

untagged=0 notarize=1 release=1 run_tests=1
for arg in "$@"; do
    case "$arg" in
        --untagged) untagged=1 release=0 ;;
        --no-notarize) notarize=0 release=0 ;;
        --no-release) release=0 ;;
        --skip-tests) run_tests=0 ;;
        -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'release: unknown option %s\n' "$arg" >&2; exit 2 ;;
    esac
done

fail() { printf 'release: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

# The project is the one source of the version (check_version.sh checks it's consistent).
project_setting() {
    sed -n "s/^[[:space:]]*$1 = \"\{0,1\}\([^\";]*\)\"\{0,1\};$/\1/p" \
        "$project_dir/FunesVault.xcodeproj/project.pbxproj" | head -n 1
}
version=$(project_setting MARKETING_VERSION)
build_number=$(project_setting CURRENT_PROJECT_VERSION)
info_plist="$project_dir/Apps/FunesMac-Info.plist"
public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info_plist" 2>/dev/null || true)
feed_url=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info_plist" 2>/dev/null || true)
tag="v$version"
archive="$build_dir/$app_name.xcarchive"
app="$build_dir/export/$app_name.app"
dmg="$dist_dir/$app_name-$version.dmg"
stable_dmg="$dist_dir/$app_name.dmg"
zip="$dist_dir/$app_name-$version.zip"

# 1. A clean tree at a matching tag (or --untagged), and a consistent version.
step "Checking the tree and the version"
[ -z "$(git -C "$project_dir" status --porcelain)" ] \
    || fail "the working tree has uncommitted changes; commit or stash them first"
if [ "$untagged" = 1 ]; then
    printf 'Untagged rehearsal of %s (%s) at %s\n' "$version" "$build_number" \
        "$(git -C "$project_dir" rev-parse --short HEAD)"
    sh "$project_dir/scripts/check_version.sh"
else
    git -C "$project_dir" tag --points-at HEAD | grep -qx "$tag" \
        || fail "HEAD isn't tagged $tag (the project says $version); tag it, or pass --untagged for a rehearsal"
    sh "$project_dir/scripts/check_version.sh" "$tag"
fi
if [ "$release" = 1 ]; then
    [ -n "$public_key" ] && [ -n "$feed_url" ] \
        || fail "Apps/FunesMac-Info.plist needs SUFeedURL and SUPublicEDKey before a release"
fi

# The signing identity: a Developer ID unless this is a rehearsal.
if [ -z "${FUNES_SIGN_IDENTITY:-}" ]; then
    found=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | tr -d '"' | sort -u || true)
    [ -n "$found" ] || fail "no \"Developer ID Application\" identity in the keychain; set FUNES_SIGN_IDENTITY"
    [ "$(printf '%s\n' "$found" | wc -l)" -eq 1 ] \
        || fail "more than one Developer ID Application identity; set FUNES_SIGN_IDENTITY to one of:
$found"
    FUNES_SIGN_IDENTITY=$found
fi
security find-identity -v -p codesigning | grep -qF "\"$FUNES_SIGN_IDENTITY\"" \
    || fail "the identity \"$FUNES_SIGN_IDENTITY\" isn't a valid code-signing identity in the keychain"
case "$FUNES_SIGN_IDENTITY" in
    "Developer ID Application: "*"($team_id)") ;;
    *) fail "a release is signed with the Developer ID Application identity of team $team_id, not \"$FUNES_SIGN_IDENTITY\"" ;;
esac
# The Developer ID profile that lets the app use CloudKit (ADR-0019). Without it a hardened,
# Developer ID-signed app with the iCloud entitlement wouldn't launch. Prints its UUID.
find_profile() {
    set -- "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.provisionprofile \
        "$HOME/Library/MobileDevice/Provisioning Profiles"/*.provisionprofile
    python3 - "$profile_name" "$team_id" "$bundle_id" "$icloud_container" "$@" <<'PYTHON'
import datetime, plistlib, subprocess, sys
name, team, bundle_id, container, *paths = sys.argv[1:]
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
valid, rejected = [], []
for path in paths:
    try:
        decoded = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True, check=True)
        profile = plistlib.loads(decoded.stdout)
    except (OSError, subprocess.CalledProcessError, plistlib.InvalidFileException):
        continue
    if profile.get("Name") != name:
        continue
    entitlements = profile.get("Entitlements", {})
    problems = []
    if team not in profile.get("TeamIdentifier", []):
        problems.append(f"not team {team}")
    if entitlements.get("com.apple.application-identifier") != f"{team}.{bundle_id}":
        problems.append(f"not for {bundle_id}")
    if not profile.get("ProvisionsAllDevices"):
        problems.append("not a Developer ID profile")
    if container not in entitlements.get("com.apple.developer.icloud-container-identifiers", []):
        problems.append(f"no iCloud container {container}")
    if "Production" not in entitlements.get("com.apple.developer.icloud-container-environment", []):
        problems.append("no CloudKit Production environment")
    if profile.get("ExpirationDate", now) <= now:
        problems.append(f"expired {profile.get('ExpirationDate'):%Y-%m-%d}")
    if problems:
        rejected.append(f"{path}: {', '.join(problems)}")
    else:
        valid.append((profile["ExpirationDate"], profile["UUID"]))
for line in rejected:
    print(f"release: skipping {line}", file=sys.stderr)
if not valid:
    sys.exit(1)
expiry, uuid = max(valid)
print(uuid, f"{expiry:%Y-%m-%d}")
PYTHON
}
profile_line=$(find_profile) \
    || fail "no valid Developer ID provisioning profile \"$profile_name\" for $bundle_id with $icloud_container is installed; download it in Xcode ▸ Settings ▸ Accounts (Download Manual Profiles) or set FUNES_MAC_PROFILE (docs/MAINTAINING.md)"
profile_uuid=${profile_line%% *}
profile_expiry=${profile_line#* }
if [ "$notarize" = 1 ]; then
    if [ -n "${FUNES_NOTARY_PROFILE:-}" ]; then
        :
    elif [ -n "${FUNES_NOTARY_KEY:-}" ] && [ -n "${FUNES_NOTARY_KEY_ID:-}" ]; then
        [ -f "$FUNES_NOTARY_KEY" ] || fail "FUNES_NOTARY_KEY $FUNES_NOTARY_KEY isn't a file"
    else
        fail "set FUNES_NOTARY_PROFILE, or FUNES_NOTARY_KEY and FUNES_NOTARY_KEY_ID (pass --no-notarize for a rehearsal)"
    fi
fi
sparkle_signing=0
if [ -n "${FUNES_SPARKLE_KEY_FILE:-}" ] || [ "${FUNES_SPARKLE_KEYCHAIN:-0}" = 1 ]; then
    if [ -n "${FUNES_SPARKLE_KEY_FILE:-}" ]; then
        [ -f "$FUNES_SPARKLE_KEY_FILE" ] || fail "FUNES_SPARKLE_KEY_FILE $FUNES_SPARKLE_KEY_FILE isn't a file"
    fi
    [ -n "$public_key" ] || fail "a Sparkle key is set but the app has no SUPublicEDKey to check it with"
    sparkle_signing=1
fi
if [ "$release" = 1 ] && [ "$sparkle_signing" = 0 ]; then
    fail "set FUNES_SPARKLE_KEY_FILE (or FUNES_SPARKLE_KEYCHAIN=1): without an appcast, installed copies won't see this release"
fi
if [ "$release" = 1 ]; then
    command -v gh > /dev/null || fail "gh (the GitHub CLI) is needed to create the draft release"
    gh auth status > /dev/null 2>&1 || fail "gh isn't signed in"
    ! gh release view "$tag" --repo "$repo" > /dev/null 2>&1 \
        || fail "a release $tag already exists in $repo; delete the draft first"
fi
printf 'Signing as %s\n' "$FUNES_SIGN_IDENTITY"
printf 'Provisioning profile "%s" (%s, expires %s)\n' "$profile_name" "$profile_uuid" "$profile_expiry"

# With an API key file, the issuer is only passed when set (individual keys have none).
notarytool() {
    if [ -n "${FUNES_NOTARY_PROFILE:-}" ]; then
        xcrun notarytool "$@" --keychain-profile "$FUNES_NOTARY_PROFILE"
    elif [ -n "${FUNES_NOTARY_ISSUER:-}" ]; then
        xcrun notarytool "$@" --key "$FUNES_NOTARY_KEY" --key-id "$FUNES_NOTARY_KEY_ID" \
            --issuer "$FUNES_NOTARY_ISSUER"
    else
        xcrun notarytool "$@" --key "$FUNES_NOTARY_KEY" --key-id "$FUNES_NOTARY_KEY_ID"
    fi
}

# notarytool's JSON result (its last JSON object; warnings may precede it) as
# "<id> <status>", or nothing when there is no result.
notary_result() {
    python3 -c '
import json, re, sys
text = sys.stdin.read()
for match in reversed(list(re.finditer(r"^\{", text, re.M))):
    try:
        outcome = json.loads(text[match.start():])
    except ValueError:
        continue
    print(outcome.get("id", "?"), outcome.get("status", "?"))
    break
'
}

# Submits a file and waits. On anything but Accepted, prints Apple's log.
notarize_file() {
    result=$(notarytool submit "$1" --wait --timeout 45m --output-format json 2>&1) || true
    parsed=$(printf '%s\n' "$result" | notary_result)
    if [ -z "$parsed" ]; then
        printf '%s\n' "$result" >&2
        fail "notarytool returned no result for $(basename "$1")"
    fi
    submission_id=${parsed%% *}
    submission_status=${parsed#* }
    printf 'Submission %s: %s\n' "$submission_id" "$submission_status"
    [ "$submission_status" = "Accepted" ] && return 0
    printf 'Notarization log for %s:\n' "$submission_id" >&2
    notarytool log "$submission_id" >&2 || true
    fail "notarization of $(basename "$1") failed ($submission_status)"
}

# 2. The bundled model (cached after the first run), then the tests, which use it.
step "Fetching the embedding model"
sh "$project_dir/scripts/fetch_embedding_model.sh"
if [ "$run_tests" = 1 ]; then
    step "Running the offline tests"
    FUNES_REQUIRE_EMBEDDING_MODEL=1 sh "$project_dir/scripts/test.sh"
else
    step "Skipping the offline tests (--skip-tests)"
fi

# 3. A universal archive, signed with the Developer ID identity and the Developer ID profile
# (manual signing: no development certificate is needed, and Release injects no
# get-task-allow). Only the FunesMac target reads FUNES_RELEASE_ENTITLEMENTS and
# FUNES_RELEASE_PROFILE, so the app gets iCloud and funes-mcp stays without entitlements.
# The Embed Resources phase copies the model in and fails without it.
step "Archiving the universal app"
rm -rf "$build_dir" "$dist_dir"
mkdir -p "$build_dir" "$dist_dir"
xcodebuild -project "$project_dir/FunesVault.xcodeproj" -scheme FunesMac -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$build_dir/DerivedData" \
    -clonedSourcePackagesDirPath "$packages_dir" -archivePath "$archive" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$FUNES_SIGN_IDENTITY" DEVELOPMENT_TEAM="$team_id" \
    FUNES_RELEASE_ENTITLEMENTS=Apps/FunesMac.entitlements FUNES_RELEASE_PROFILE="$profile_uuid" \
    archive -quiet

# 4. Export with Developer ID: Xcode re-signs every piece inside out with a secure timestamp,
# embeds the profile and sets the iCloud environment to Production, the one the App Store
# iPhone app uses.
step "Exporting with Developer ID"
cat > "$build_dir/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>$FUNES_SIGN_IDENTITY</string>
	<key>teamID</key>
	<string>$team_id</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>$bundle_id</key>
		<string>$profile_uuid</string>
	</dict>
	<key>iCloudContainerEnvironment</key>
	<string>Production</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$build_dir/export" \
    -exportOptionsPlist "$build_dir/ExportOptions.plist" > "$build_dir/export.log" 2>&1 \
    || { cat "$build_dir/export.log" >&2; fail "the export failed"; }
[ -d "$app" ] || fail "the export has no $app_name.app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version" ] \
    || fail "the exported app's version isn't $version"
if [ -n "$public_key" ]; then
    sh "$project_dir/scripts/check_bundle.sh" "$app" arm64 x86_64
else
    # A rehearsal before the Sparkle keys exist: everything else is checked.
    FUNES_ALLOW_NO_UPDATES=1 sh "$project_dir/scripts/check_bundle.sh" "$app" arm64 x86_64
fi

# 5. Notarize the app and staple the ticket.
if [ "$notarize" = 1 ]; then
    step "Notarizing the app"
    ditto -c -k --keepParent "$app" "$build_dir/notarize-$app_name.zip"
    notarize_file "$build_dir/notarize-$app_name.zip"
    rm -f "$build_dir/notarize-$app_name.zip"
    xcrun stapler staple -q "$app"
    sh "$project_dir/scripts/check_notarized.sh" "$app"
else
    step "Skipping notarization (--no-notarize)"
    sh "$project_dir/scripts/check_notarized.sh" "$app" --signed-only
fi

# 6. The DMG (drag to Applications), signed, notarized and stapled; then the zip from the
# stapled app, which Sparkle installs from.
step "Building the disk image"
sh "$project_dir/scripts/make_dmg.sh" "$app" "$display_name" "$dmg"
codesign --force --sign "$FUNES_SIGN_IDENTITY" --timestamp --identifier "com.funesvault.mac.dmg" "$dmg"
if [ "$notarize" = 1 ]; then
    step "Notarizing the disk image"
    notarize_file "$dmg"
    xcrun stapler staple -q "$dmg"
    sh "$project_dir/scripts/check_notarized.sh" "$dmg"
else
    sh "$project_dir/scripts/check_notarized.sh" "$dmg" --signed-only
fi

step "Building the zip"
ditto -c -k --keepParent "$app" "$zip"

# 7. Checksums, and the Sparkle appcast when a key is given.
step "Writing checksums and release notes"
# The same DMG as FunesVault.dmg, so releases/latest/download/FunesVault.dmg always works,
# and SHA256SUMS for all three downloads.
sh "$project_dir/scripts/release_assets.sh" "$dist_dir" "$app_name" "$version"
cat "$dist_dir/SHA256SUMS"
python3 "$project_dir/scripts/release_notes.py" "$version" --repo "$repo" --format markdown \
    > "$build_dir/notes-section.md"
python3 "$project_dir/scripts/release_notes.py" "$version" --repo "$repo" --format html \
    > "$build_dir/notes.html"
if [ "$sparkle_signing" = 1 ]; then
    step "Signing the zip for Sparkle and writing the appcast"
    sparkle_bin=${FUNES_SPARKLE_BIN:-$packages_dir/artifacts/sparkle/Sparkle/bin}
    sign_update="$sparkle_bin/sign_update"
    [ -x "$sign_update" ] || fail "Sparkle's sign_update isn't at $sign_update; set FUNES_SPARKLE_BIN"
    if [ -n "${FUNES_SPARKLE_KEY_FILE:-}" ]; then
        signature_line=$("$sign_update" --ed-key-file "$FUNES_SPARKLE_KEY_FILE" "$zip")
    else
        signature_line=$("$sign_update" --account "$sparkle_account" "$zip")
    fi
    # The check installed copies will make: the signature against SUPublicEDKey.
    signature=$(printf '%s\n' "$signature_line" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
    xcrun swiftc -O -o "$build_dir/verify-update-signature" "$project_dir/scripts/verify_update_signature.swift"
    "$build_dir/verify-update-signature" "$public_key" "$zip" "$signature" \
        || fail "the Sparkle key doesn't match SUPublicEDKey in the app"
    minimum_macos=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")
    python3 "$project_dir/scripts/appcast.py" \
        --version "$version" --build "$build_number" --minimum-system-version "$minimum_macos" \
        --url "https://github.com/$repo/releases/download/$tag/$(basename "$zip")" \
        --signature-line "$signature_line" --notes-html "$build_dir/notes.html" \
        --title "$display_name $version" --link "https://github.com/$repo/releases/tag/$tag" \
        --output "$dist_dir/appcast.xml"
else
    printf 'No Sparkle key (FUNES_SPARKLE_KEY_FILE or FUNES_SPARKLE_KEYCHAIN=1): appcast.xml not written\n'
fi
# The notes for the GitHub release: the CHANGELOG section, then how to install and verify.
# Only claims that hold for this build are made (a rehearsal isn't notarized; only the
# workflow attests; only a release with an appcast updates).
minimum_macos=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")
{
    cat "$build_dir/notes-section.md"
    printf '\n## Install\n\n'
    printf 'Download `%s` (`%s` is the same file, under a name that stays the same in every release), open it and drag the app to **Applications**. Or install it with Homebrew: `brew install --cask bereciartua/tap/funes-vault`. It needs macOS %s or later, on Apple silicon or Intel. ' \
        "$(basename "$dmg")" "$(basename "$stable_dmg")" "$minimum_macos"
    printf 'Your vault stays on this Mac, in `~/Library/Application Support/FunesVault`; replacing an installed copy keeps it, with your agents and their access.'
    earlier=$(git -C "$project_dir" tag --list 'v*' | grep -vx "$tag" | head -n 1 || true)
    if [ -f "$dist_dir/appcast.xml" ] && [ -n "$earlier" ]; then
        printf ' An installed copy offers this version from **Check for Updates…**.'
    fi
    printf '\n\n## Checksums (SHA-256)\n\n```\n'
    cat "$dist_dir/SHA256SUMS"
    printf '```\n\n'
    if [ "$notarize" = 1 ]; then
        printf 'The app and the disk image are signed with a Developer ID and notarized by Apple.'
    else
        printf '**Rehearsal build:** signed, but not notarized; Gatekeeper blocks it on other Macs.'
    fi
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
        printf ' Built by the release workflow: `gh attestation verify %s --repo %s` checks the provenance of each download.' \
            "$(basename "$dmg")" "$repo"
    fi
    printf '\n'
} > "$dist_dir/RELEASE-NOTES.md"

# 8. A draft release for the maintainer to review and publish.
if [ "$release" = 1 ]; then
    step "Creating the draft release $tag in $repo"
    set -- "$dmg" "$stable_dmg" "$zip" "$dist_dir/SHA256SUMS"
    [ -f "$dist_dir/appcast.xml" ] && set -- "$@" "$dist_dir/appcast.xml"
    gh release create "$tag" --repo "$repo" --draft --verify-tag \
        --title "$display_name $version" --notes-file "$dist_dir/RELEASE-NOTES.md" "$@"
    printf 'Draft created: review it at https://github.com/%s/releases, then publish it.\n' "$repo"
else
    step "No GitHub release (rehearsal); the files are in dist/"
fi
ls -l "$dist_dir"
