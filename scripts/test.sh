#!/bin/sh
# Offline checks: package tests, the log-privacy check and an unsigned
# build of the Mac app. Used locally and in CI.
set -eu
cd "$(dirname "$0")/.."

sh scripts/check_log_privacy.sh
swift test --package-path Packages/FunesProtocol
swift test --package-path Packages/FunesCore
xcodebuild -project FunesVault.xcodeproj -scheme FunesMac -configuration Debug \
    -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO build -quiet
echo "test.sh: all green"
