#!/bin/sh
set -eu

# Captures the iPhone app's App Store screenshots (spec/release/app-store/screenshots.md) from
# demo mode, at 6.9" (1320 × 2868), on an iPhone 17 Pro Max simulator. A Debug build opens each
# scene itself with -FunesScreenshot <scene> (Apps/FunesiOS/ScreenshotScene.swift), so nothing is
# tapped. Needs an iOS simulator runtime (xcodebuild -downloadPlatform iOS).
#
# Usage: sh scripts/app_store_screenshots.sh [output folder]   (default build/app-store-screenshots)
#
# Environment:
#   FUNES_SIM_DEVICE   A simulator's UDID or name. Default: "Funes Screenshots", created if missing.

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-$project_dir/build/app-store-screenshots}
derived="$project_dir/build/sim"
device_name=${FUNES_SIM_DEVICE:-Funes Screenshots}
scenes="capture share access search inbox save"

fail() { printf 'app_store_screenshots: %s\n' "$*" >&2; exit 1; }

runtime=$(xcrun simctl list runtimes | sed -n 's/.* - \(com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]*\)$/\1/p' | tail -n 1)
[ -n "$runtime" ] || fail "no iOS simulator runtime; install one with xcodebuild -downloadPlatform iOS"
udid=$(xcrun simctl list devices | sed -n "s/^ *$device_name (\([0-9A-F-]*\)) .*/\1/p" | head -n 1)
case "$device_name" in *-*-*-*-*) udid=$device_name ;; esac
if [ -z "$udid" ]; then
    udid=$(xcrun simctl create "$device_name" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max "$runtime")
fi
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b > /dev/null
xcrun simctl ui "$udid" appearance light
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3

printf '==> Building for the simulator\n'
xcodebuild -project "$project_dir/FunesVault.xcodeproj" -scheme FunesiOS -configuration Debug \
    -destination "id=$udid" -derivedDataPath "$derived" -quiet build
app="$derived/Build/Products/Debug-iphonesimulator/FunesiOS.app"
xcrun simctl install "$udid" "$app"

mkdir -p "$out"
n=0
for scene in $scenes; do
    n=$((n + 1))
    xcrun simctl terminate "$udid" com.funesvault.ios 2>/dev/null || true
    xcrun simctl launch "$udid" com.funesvault.ios -FunesScreenshot "$scene" > /dev/null
    # Demo mode, the first loads and a sheet's animation.
    sleep 5
    xcrun simctl io "$udid" screenshot "$out/$n-$scene.png" > /dev/null 2>&1
    printf '  %s\n' "$out/$n-$scene.png"
done
xcrun simctl terminate "$udid" com.funesvault.ios 2>/dev/null || true
printf '==> %s screenshots in %s (1320 × 2868)\n' "$n" "$out"
