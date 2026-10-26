#!/bin/sh
# Offline checks: package tests, the log-privacy check, the MCP harness and unsigned
# builds of the Mac and iPhone apps. Used locally and in CI.
set -eu
cd "$(dirname "$0")/.."

sh scripts/check_log_privacy.sh
# The App Store texts fit App Store Connect's limits (task 5.7).
sh scripts/check_app_store_metadata.sh
# Text reaches a model only through ModelRouter.send, whose guardrails can't be skipped (model
# providers §5, PR #3 review 4304236136).
if grep -rn --include='*.swift' '\.generate(' Apps Packages | grep -v '/Tests/' \
    | grep -v '^Packages/FunesCore/Sources/FunesCore/Models/ModelRouter.swift:.*try await provider.generate(request)'; then
    echo "test.sh: call models through ModelRouter.send, not .generate(" >&2
    exit 1
fi
# Memory text reaches a provider embedding model only through ModelRouter.embed (ADR-0023); only
# the bundled index (EmbeddingIndexer, on-device by precondition) calls its model directly.
if grep -rn --include='*.swift' '\.embed(' Apps Packages | grep -v '/Tests/' | grep -v 'ModelRouter\.embed(' \
    | grep -v 'indexer\.provider\.embed(' \
    | grep -v '^Packages/FunesCore/Sources/FunesCore/Search/EmbeddingIndex.swift:.*try await provider.embed(' \
    | grep -v '^Packages/FunesCore/Sources/FunesCore/Models/ModelRouter.swift:.*provider.embed('; then
    echo "test.sh: call provider embedding models through ModelRouter.embed, not .embed(" >&2
    exit 1
fi
swift test --package-path Packages/FunesProtocol
swift test --package-path Packages/FunesCore
# The overview's 50 ms budget on a 10,000-memory vault (FR-H-01), alone so no other test shares
# the CPU. Not on CI, whose shared runners' timings say little.
if [ -z "${CI:-}" ]; then
    FUNES_OVERVIEW_BENCHMARK=1 swift test --package-path Packages/FunesCore --filter OverviewBenchmarkTests
fi
swift test --package-path Packages/FunesMCP
swift test --package-path Packages/BridgeUI
swift test --package-path Packages/FunesCompanion
swift test --package-path Packages/FunesPhone
# The MCP tool paths over loopback, against the FUNES_MCP_TEST server.
swift build --package-path Packages/FunesMCP --product funes-mcp-test-server
PYTHONPYCACHEPREFIX="$PWD/build/pycache" python3 Tests/mcp/mcp_test.py \
    "$(swift build --package-path Packages/FunesMCP --show-bin-path)/funes-mcp-test-server" Tests/mcp/fixtures/tools.json
# Remote Access over loopback (Phase 4b): the gate, cloud credentials, OAuth pairing, and the
# same decision for the same agent and request on both listeners.
PYTHONPYCACHEPREFIX="$PWD/build/pycache" python3 Tests/mcp/remote_test.py \
    "$(swift build --package-path Packages/FunesMCP --show-bin-path)/funes-mcp-test-server"
xcodebuild -project FunesVault.xcodeproj -scheme FunesMac -configuration Debug \
    -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=YES build -quiet
# The UI-review build (task 3.10) still compiles; scripts/ui_snapshots.sh runs it.
xcodebuild -project FunesVault.xcodeproj -scheme FunesMac -configuration Debug \
    -destination 'generic/platform=macOS' -derivedDataPath build/ui-review \
    CODE_SIGNING_ALLOWED=NO SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG FUNES_UI_REVIEW' build -quiet
# The iPhone app and its extensions (Phase 5), for a generic device: no simulator runtime needed.
xcodebuild -project FunesVault.xcodeproj -scheme FunesiOS -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=YES build -quiet
# Every user-facing string is in a String Catalog (NFR-L10N-01).
CHECK=1 sh scripts/sync_strings.sh
echo "test.sh: all green"
