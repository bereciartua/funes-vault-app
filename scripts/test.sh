#!/bin/sh
# Offline checks: package tests, the log-privacy check, the MCP harness and an
# unsigned build of the Mac app. Used locally and in CI.
set -eu
cd "$(dirname "$0")/.."

sh scripts/check_log_privacy.sh
swift test --package-path Packages/FunesProtocol
swift test --package-path Packages/FunesCore
swift test --package-path Packages/FunesMCP
swift test --package-path Packages/BridgeUI
# The MCP tool paths over loopback, against the FUNES_MCP_TEST server.
swift build --package-path Packages/FunesMCP --product funes-mcp-test-server
PYTHONPYCACHEPREFIX="$PWD/build/pycache" python3 Tests/mcp/mcp_test.py \
    "$(swift build --package-path Packages/FunesMCP --show-bin-path)/funes-mcp-test-server" Tests/mcp/fixtures/tools.json
xcodebuild -project FunesVault.xcodeproj -scheme FunesMac -configuration Debug \
    -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=YES build -quiet
# Every user-facing string is in the String Catalog (NFR-L10N-01).
CHECK=1 sh scripts/sync_strings.sh
echo "test.sh: all green"
