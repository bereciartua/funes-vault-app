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
# The menu bar panel never answers anything: a card's Review only opens the item's own panel,
# which keeps its arming delay and keys (FR-G-01, ADR-0029).
if grep -nE '\.(withdraw|withdrawAll|answerSignIn|answerPairing|approve|deny|laterForAllSaves|apply\(suggestionID)\(|queue\.answer\(' \
    Apps/FunesMac/MenuBar/*.swift Packages/BridgeUI/Sources/BridgeUI/MenuBarPanel.swift Packages/BridgeUI/Sources/BridgeUI/PanelField.swift; then
    echo "test.sh: the menu bar panel must not answer requests, suggestions or sign-ins" >&2
    exit 1
fi
# Facts qualification records (Phase 13a.2 Gates): every shipped record's measures recomputed from its evidence, and the
# record writer's fail-closed checks on synthetic runs.
(cd spikes/people && PYTHONPYCACHEPREFIX="$PWD/../../build/pycache" python3 -m unittest -q test_qualify.py \
    && PYTHONPYCACHEPREFIX="$PWD/../../build/pycache" python3 qualify.py verify)
swift test --package-path Packages/FunesProtocol
swift test --package-path Packages/FunesCore
# The CLI runner with the global dispatch pool blocked (a busy Mac, a loaded CI runner), alone:
# blocking the pool would stall every other test in the process.
FUNES_RUNNER_STARVATION_TEST=1 swift test --skip-build --package-path Packages/FunesCore \
    --filter theProcessRunnerDoesNotNeedTheGlobalQueues
# The overview's 50 ms budget on a 10,000-memory vault (FR-H-01), alone so no other test shares
# the CPU. Not on CI, whose shared runners' timings say little.
if [ -z "${CI:-}" ]; then
    # A benchmark that misses its budget prints the load and the busiest processes with the
    # failure. If other processes were keeping half the cores or more busy when it failed
    # (Spotlight, Time Machine, a parallel build), it runs once more, and must meet its budget
    # then; otherwise the failure stands. Each is built before it runs, so a build isn't counted.
    benchmark() {
        if "$@"; then return 0; fi
        cores=$(sysctl -n hw.ncpu)
        busy=$(LC_ALL=C ps -Ao pcpu= | LC_ALL=C awk '{ s += $1 } END { print s / 100 }')
        echo "test.sh: benchmark failed with $(LC_ALL=C awk -v b="$busy" 'BEGIN { printf "%.1f", b }') of $cores cores busy (CPU over about the last" \
            "minute); load averages $(LC_ALL=C sysctl -n vm.loadavg)" >&2
        LC_ALL=C ps -Ao pcpu=,comm= -r | head -5 | sed -E 's#^ *([0-9.]+) (.*/)?#test.sh:   \1% #' >&2
        if LC_ALL=C awk -v b="$busy" -v c="$cores" 'BEGIN { exit !(b >= c / 2) }'; then
            echo "test.sh: the Mac was busy; running the benchmark once more" >&2
            if "$@"; then
                echo "test.sh: the benchmark passed on its second run" >&2
                return 0
            fi
        fi
        return 1
    }
    benchmark env FUNES_OVERVIEW_BENCHMARK=1 swift test --skip-build --package-path Packages/FunesCore \
        --filter OverviewBenchmarkTests
    # Search with snippets within FR-V-10's 150 ms on 10,000 memories (FR-V-17), and search with
    # learned facts' links within it (Phase 13b), each alone likewise, and in release: the budget
    # is the shipped app's.
    swift build --build-tests -c release -Xswiftc -enable-testing --package-path Packages/FunesCore
    for suite in SnippetBenchmarkTests FactsSearchBenchmarkTests; do
        benchmark env FUNES_SEARCH_BENCHMARK=1 swift test --skip-build -c release -Xswiftc -enable-testing \
            --package-path Packages/FunesCore --filter "$suite"
    done
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
