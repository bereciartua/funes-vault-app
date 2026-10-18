# Testing and evidence

What has been tested, how, and what's still open. The approach is in the [testing strategy](../spec/plans/testing-strategy.md): tests are the specification for the privacy guarantees, golden files pin the external contracts, and a recorded live matrix shows how real agents behave.

## Repeatable checks

Everything below runs with one command, offline, without touching your vault, your agents' configs or the network (the embedding model aside, which `scripts/fetch_embedding_model.sh` fetches once):

```sh
sh scripts/fetch_embedding_model.sh
sh scripts/test.sh
```

Continuous integration (`.github/workflows/ci.yml`) runs the same on pull requests that change code, on GitHub's macOS runners with Xcode 27.0 (and Xcode 26.6 on a manual run), with `FUNES_REQUIRE_EMBEDDING_MODEL=1`, so the model-dependent tests fail instead of skipping. No secrets are involved.

| Check | What it establishes |
| --- | --- |
| Log privacy (`scripts/check_log_privacy.sh`) | No `print`, `debugPrint`, `dump` or `NSLog` in app or package sources, and no `privacy: .public` without a `// log-safe:` reason on the same line. |
| One way to a model | Nothing calls a model provider's `generate` except `ModelRouter.send`, which applies the secret scanner and the cloud limit. |
| `FunesProtocol` tests | The secret scanner's patterns (positives, negatives, Luhn), sensitivity order and coding, input limits counted in Unicode scalars, expiry boundaries, the built-in categories, and the identifiers against the spec. |
| `FunesCore` tests | The access policy's test vectors (gate order, eligibility, decisions, allow windows), disclosures (snapshot, approval with a stale revision, single-use delivery, invalidation on change, expiry, concurrency limits), suggestions and corrections, captures, agents and keys, access requests (Allow Once, Always Allow, once an hour), the store and its migrations, import and export (no keys or access in exports), model providers against stubbed HTTP (request shapes, fallbacks, and guardrails: no secret and nothing above the cloud limit in any captured request), and the search regression. |
| Search regression | On the 200 fixture memories and 30 agent-style tasks (`Packages/FunesCore/Tests/FunesCoreTests/fixtures/`): hybrid recall@5 ≥ 0.92 with agent keywords and ≥ 0.68 without, keyword-only ≥ 0.82 with keywords. The Swift WordPiece tokenizer matches Hugging Face's ids on the fixture texts. |
| `FunesMCP` tests | The tool contract matches `Tests/mcp/fixtures/tools.json` byte for byte; the five tools in order; tool visibility for each access, and an unreadable agent failing closed; annotations; schema lengths counted in characters. |
| `BridgeUI` tests | The approval queue (first in, first out, at most 3 shown, countdown, exactly-once answers, withdraw on quit, re-arming when content changes), panel content (exact text, keywords, Show all), the Activity store (append, retention, compaction), the updater's relaunch gate, the install-location check, and agent setups. |
| Agent setup goldens | Every copyable setup in `Packages/BridgeUI/Tests/BridgeUITests/fixtures/agent-setup/` byte for byte, including paths with spaces and apostrophes; no snippet contains a key; JSON and TOML parse; each one-click setup matches its snippet; one-click file merges keep a backup, leave invalid files alone and run agents' commands in the given home. |
| MCP harness (`Tests/mcp/mcp_test.py`) | Drives `funes-mcp-test-server` (the real listener, server, pipeline, handlers, vault and key files on a temporary vault, with a fake approval responder and a short in-call wait) over real loopback sockets: `initialize` and the instructions; 401 for missing, unknown and EK Bridge keys, 403 for forwarded requests, 421 for a foreign `Host`; the endpoint and key files' contents and modes; schema refusals with field paths; every tool's paths, including approve, deny, timeout then `get_memory_request`, single use, `policy_changed`, another agent's request, suggestions queued, saved and refused (secrets, unknown categories, bad dates, oversize metadata, above the ceiling), `open_in_funes`, and asking for more access; paused Funes, paused, expired, rotated and removed agents; withheld memory ids never in Activity; and the rate limits (3 pending requests per agent under concurrency, the call burst, the write burst). |
| App builds | An unsigned Debug build of the app and the launcher, and the UI-review build (`FUNES_UI_REVIEW`), both compile. |
| String catalog | `CHECK=1 sh scripts/sync_strings.sh`: every user-facing string is in `Apps/FunesMac/Localizable.xcstrings`. |

Regenerate golden files after an intended change with `UPDATE_GOLDENS=1 sh scripts/test.sh`, and review the diff.

**Not in `test.sh`:** the screenshots (`sh scripts/ui_snapshots.sh`, which needs a logged-in GUI session and Screen Recording permission for the terminal, and writes light and dark PNGs of every screen, sheet and panel to `build/ui-snapshots` from fake data), and the generic protocol checks (protocol eras, statuses, slow clients, the failed-auth lockout, the launcher's listener check), which live in [BridgeKit](https://github.com/bereciartua/bridgekit)'s own test suite.

<!-- TODO(check): the testing strategy lists a launcher harness (launcher_test.py) and XCTest UI tests for Funes; neither exists in this repo yet. The launcher is covered by BridgeKit's harness. -->

## Live checks so far

These ran on the development Mac, an M1 MacBook (8 GB) with macOS 27.0.1, against Debug builds and synthetic data. Full numbers and methods are in [spike results](../spec/plans/spike-results.md).

| Date | Check | Result |
| --- | --- | --- |
| 16 Oct 2026 | **Search with Apple's embeddings** (Xcode 27.0, Swift 6.4, GRDB 7.11.1; 200 memories, 30 tasks; latency at 10,000 memories) | Fast (18 ms p50) but recall@5 only 0.58. Rejected as the default ([Spike 2](../spec/plans/spike-results.md#spike-2-search-quality-and-speed)). |
| 17 Oct 2026 | **Local open embedding models** (bge-small, e5, multilingual-e5, nomic, Qwen3; PyTorch 2.14.1 and Core ML) | bge-small-en-v1.5 as Core ML on the CPU: recall@5 0.94 with agent keywords, 10.5 ms per search end to end at 10,000 memories. Chosen ([Spike 2b](../spec/plans/spike-results.md#spike-2b-local-open-source-embeddings), ADR-0016). |
| 16 Oct 2026 <!-- TODO(check): spike-results.md records this run as 2026-10-16, a day before Spike 2b, which it re-measures. --> | **Search re-measured inside FunesCore** with the shipped int8 model | Recall@5 0.939 with keywords, 0.689 without; keyword-only 0.828. The tokenizer matched Hugging Face on all 268 fixture texts. Keyword floor 0.15 chosen. These are the regression baselines above. |
| 16 Oct 2026 | **Agent timeouts** with a throwaway stdio server: Claude Code 2.1.288 and Codex CLI 0.160.0, headless | Neither timed out at 45 s (Claude Code ≥ 300 s, Codex ≥ 90 s measured). Both relayed "Waiting for your approval in Funes." and waited about a minute before checking back; neither retried a call on its own ([Spike 3](../spec/plans/spike-results.md#spike-3-agent-timeouts-and-the-in-call-approval)). |
| 17 Oct 2026 | **Agents on the real MCP server**: Debug build, a development vault (`FUNES_DATA_DIR`, `--dev-seed`), Claude Code 2.1.288 and Codex CLI headless with per-run configs | `funes-mcp check` passed (key file 0600, key accepted, 5 tools, Funes Vault on). Claude Code and Codex connected through the launcher. Codex saw the Share panel time out after 45 s and relayed the message. Approve, deny, and timeout then `get_memory_request` worked with Claude Code (the timeout returned at 45.1 s). A suggest-only agent's suggestion was queued with its Save panel. Both agents sent `keywords` unprompted. A timer drift (45 s ran to about 47 s) was found and fixed. |
| 17 Oct 2026 | **The panels by hand**, in the real app (Debug build `1dad5fb`, a test vault): Claude Code, Claude Desktop and Cursor | Share and Deny worked with Claude Code, and the Save panel showed. Claude Desktop and Cursor sent `keywords` and waited the full 45 s. The panels' look in light and dark was checked. |

No live check so far used a signed, notarized build, the launcher from an installed app, or a real vault.

## Release rehearsals

| Date | Commit | Command | Result |
| --- | --- | --- | --- |
| 17 Oct 2026 | `c4ca516` (+ a rehearsal-only commit with a throwaway Sparkle key, because Funes's own key didn't exist yet) | `FUNES_NOTARY_PROFILE=ekbridge FUNES_SPARKLE_KEY_FILE=<throwaway> sh scripts/release.sh --untagged --no-release`, Xcode 27.0, macOS 27 | `test.sh` green; universal archive and Developer ID export; `check_bundle.sh` passed (arm64 + x86_64, `funes-mcp` as `com.funesvault.mac.mcp`, no `get-task-allow`, the pinned model inside); app and DMG notarization **Accepted** and stapled; `spctl`: `accepted, source=Notarized Developer ID` for both; `verify-update-signature`: the zip matches `SUPublicEDKey`; `appcast.xml` written. To repeat with Funes's own key (`FUNES_SPARKLE_KEYCHAIN=1`) once it's in `Info.plist`. |

## Live agent matrix

To run before each release, with a signed build installed in `/Applications`, a throwaway agent per row, and a vault of synthetic memories. Record each result with the date, app version and agent version; no memory text, keys or raw logs.

| Check | Claude Code | Claude Desktop | Cursor | Codex |
| --- | --- | --- | --- | --- |
| Connect (one-click setup, then `funes-mcp check`) | | | | |
| Request, approved in the panel → `delivered` | | | | |
| Request, denied → `denied_by_user` | | | | |
| Request, no answer for 45 s → `needs_approval`; shared from Pending requests; then `get_memory_request` → `delivered` | | | | |
| Suggest as a suggest-only agent → `queued`, in the Inbox, Save panel shown | | | | |
| Suggest with Write and Ask before saving off → `saved` | | | | |
| Paused agent → `agent_paused`; resumed without reconnecting | | | | |
| Removed agent → refused (HTTP 401) | | | | |

Agent versions: Claude Code —, Claude Desktop —, Cursor —, Codex —. App version: —. Date: —.

## Release install test

Before the first public release, and after any change to the bundle layout, signing or the updater. Record the date, macOS version, architecture and app version.

- [ ] Download `FunesVault.dmg` from the draft release in Safari, so it carries the quarantine flag.
- [ ] Open it: no Gatekeeper warning. `spctl --assess --type open --context context:primary-signature -v FunesVault.dmg` says `source=Notarized Developer ID`.
- [ ] Drag the app to Applications and open it: no warning; the menu bar icon appears and the Vault opens on the setup checklist.
- [ ] `sh scripts/check_bundle.sh /Applications/FunesVault.app arm64 x86_64` passes: both architectures, `funes-mcp` signed as `com.funesvault.mac.mcp` by the same team, the hardened runtime, Sparkle's feed and key, the bundled model's checksums, and the licence files.
- [ ] Vault search finds a memory by meaning, not just by its words (the model loaded).
- [ ] Add one agent, connect it with one click, and run `funes-mcp check` against it.
- [ ] `lsof -nP -iTCP -sTCP:LISTEN` shows Funes Vault only on `127.0.0.1:47625`. No firewall or Local Network prompt.
- [ ] Settings ▸ Updates shows that the app can update itself, and **Check Now** reaches the feed.
- [ ] `brew install --cask bereciartua/tap/funes-vault` on a Mac without the app installs the same version.
- [ ] If an Intel Mac is available, repeat the first five steps there.

<!-- TODO(check): no results recorded yet. -->

## Fresh-account test

On a new macOS user account (or a macOS VM), with no agents' configs and no Funes data:

- [ ] Install from the DMG and open the app. The setup checklist shows the four steps; **Found on this Mac** lists only agents that are installed.
- [ ] Answer the seed questions, and import a sample ChatGPT memories file: everything lands in the Inbox; a secret in the file is reported and not imported.
- [ ] Apply some suggestions; Vault search finds them.
- [ ] Add Claude Code (or another installed agent) with the default starting access and connect it with one click. The preview shows the exact change; the backup is written next to the config; the key isn't in it.
- [ ] Ask the agent something that needs a Low memory: the Share panel shows it; **Share** delivers it, and Activity records it by id.
- [ ] Capture with ⌥⌘M; the card gets a proposed title and categories.
- [ ] `~/Library/Application Support/FunesVault/` is mode 0700, its files 0600, and `agent-keys/` holds one key file.
- [ ] Quit: `mcp-endpoint.json` is gone.

<!-- TODO(check): no results recorded yet. -->

## Update test

**To do:** a Sparkle update from v0.1.0 to v0.1.1, through the published `appcast.xml`, before v0.1 counts as shipped.

- [ ] The installed, notarized 0.1.0 reads the published feed; **Check for Updates…** offers 0.1.1 with its release notes.
- [ ] Installing takes a click, replaces the app in `/Applications` and relaunches it as 0.1.1, signed by the same team.
- [ ] With a request waiting in Pending requests, the relaunch waits until it's answered or expires.
- [ ] After the update: the vault, agents, keys, Activity and settings are unchanged; each connected agent reconnects without a setup change; `funes-mcp check` passes.

<!-- TODO(check): EK Bridge has scripts/update_test.sh (two local builds and a local feed); there's no Funes equivalent in scripts/ yet. -->
