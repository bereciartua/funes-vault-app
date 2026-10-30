# Testing and evidence

What has been tested, how, and what's still open. The approach is in the [testing strategy](../spec/plans/testing-strategy.md): tests are the specification for the privacy guarantees, golden files pin the external contracts, and a recorded live matrix shows how real agents behave.

## Repeatable checks

Everything below runs with one command, offline, without touching your vault, your agents' configs or the network (the embedding model and the Swift package dependencies aside, fetched once; the model by `scripts/fetch_embedding_model.sh`):

```sh
sh scripts/fetch_embedding_model.sh
sh scripts/test.sh
```

Continuous integration (`.github/workflows/ci.yml`) runs the same on pull requests that change code (a pull request that only touches `spec/**`, `spikes/**` or Markdown gets a passing stub of the check instead), on GitHub's macOS runners with Xcode 27.0 (and Xcode 26.6 on a manual run), with `FUNES_REQUIRE_EMBEDDING_MODEL=1`, so the model-dependent tests fail instead of skipping. No secrets are involved.

| Check | What it establishes |
| --- | --- |
| Log privacy (`scripts/check_log_privacy.sh`) | No `print`, `debugPrint`, `dump` or `NSLog` in app or package sources, and no `privacy: .public` without a `// log-safe:` reason on the same line. |
| One way to a model | Nothing calls a model provider's `generate` except `ModelRouter.send`, and nothing calls a provider embedding model except `ModelRouter.embed`; both apply the secret scanner and the cloud limit. |
| App Store texts (`scripts/check_app_store_metadata.sh`) | The iPhone app's listing in `spec/release/app-store/` fits App Store Connect's limits, and the App Intents' titles don't name an Apple product. |
| `FunesProtocol` tests | The secret scanner's patterns (positives, negatives, Luhn), sensitivity order and coding, input limits counted in Unicode scalars, expiry boundaries, the built-in categories, and the identifiers against the spec. |
| `FunesCore` tests | The access policy's test vectors (gate order, eligibility, decisions, allow windows), disclosures (snapshot, approval with a stale revision, single-use delivery, invalidation on change, expiry, concurrency limits), suggestions and corrections, captures, agents and keys, access requests (Allow Once, Always Allow, once an hour), the store and its migrations, import and export (no keys or access in exports), cloud access and remote tokens, the migrations v1 to v6 (`CloudAccessTests`, `StoreTests`), model providers and subscription providers against stubbed HTTP and CLIs (request shapes, fallbacks, and guardrails: no secret and nothing above the cloud limit in any captured request, the daily cap), provider embeddings as a second index, the processing queue, New memories splitting and linking (`NewMemoryPipelineTests`, `ExtractionTests`, `AgentSplitTests`, auto-apply), per-action apply in the Inbox, the daily tidy-up (`TidyUpServiceTests`, the undo log), the About You profile and what each agent gets (`ProfileTests`), approvals from paired devices, the vault overview, Spike E's and Spike F's fixtures, and the search regression. |
| Overview benchmark | The vault overview answers within 50 ms on a 10,000-memory vault (`OverviewBenchmarkTests`, run alone; skipped on CI, whose shared runners' timings say little). |
| Search regression | On the 200 fixture memories and 30 agent-style tasks (`Packages/FunesCore/Tests/FunesCoreTests/fixtures/`): hybrid recall@5 ≥ 0.92 with agent keywords and ≥ 0.68 without, keyword-only ≥ 0.82 with keywords. The Swift WordPiece tokenizer matches Hugging Face's ids on the fixture texts. |
| `FunesMCP` tests | The tool contract matches `Tests/mcp/fixtures/tools.json` byte for byte; the five tools in order; tool visibility for each access, and an unreadable agent failing closed; annotations; schema lengths counted in Unicode scalars; the 200,000-byte result limit, with an id at the 1,024-byte cap; a quit while retrieving answers `funes_quit`; remote calls in flight release nothing after cloud access changes (`RemoteRevocationTests`). |
| `FunesCompanion` tests | The Mac's companion side, with the iPhone's real `CompanionClient` against the real router: pairing (expired codes, wrong proofs, Deny, too many attempts), the envelope checks in order (unknown and revoked devices, clock skew, replays, bad signatures), the address policy per mode, the listener, every method as the owner, and approvals from the iPhone (first answer wins, stale revisions, expiry, the doorbell's contents). |
| `FunesPhone` tests | The iPhone's side: the capture queue and its exactly-once delivery and backoff, address selection and retries, the approval panels' wording, the Inbox, Search and memory models, reachability and the banner, the overview cache, the widget snapshots, and demo mode. |
| `BridgeUI` tests | The approval queue (items on a clock first, soonest first, then arrival order; the chosen item stays; at most 3 shown; countdown; exactly-once answers; withdraw on quit; re-arming when content changes), panel content (exact text, keywords, Show all, weaker matches unticked, Always Allow never the default, the spoken countdown), the Activity store (append, retention, compaction), the updater's relaunch gate, the install-location check, and agent setups. `RemoteAccessControllerTests`: Funnel on 443 by path, the Incomplete and no-shareable-port states, and the automatic turn-off at launch and on resume. |
| Agent setup goldens | Every copyable setup in `Packages/BridgeUI/Tests/BridgeUITests/fixtures/agent-setup/` byte for byte, including paths with spaces and apostrophes; no snippet contains a key; JSON and TOML parse; each one-click setup matches its snippet; one-click file merges keep a backup, leave invalid files alone and run agents' commands in the given home. `RemoteSetupTests`: the `cloud-*.txt` and `tunnel-*.txt` goldens; no token or secret in any snippet; the curl snippet's round trip through `/bin/sh`; tunnel commands on the Remote Access port only. |
| MCP harness (`Tests/mcp/mcp_test.py`) | Drives `funes-mcp-test-server` (the real listener, server, pipeline, handlers, vault and key files on a temporary vault, with a fake approval responder and a short in-call wait) over real loopback sockets: `initialize` and the instructions; 401 for missing, unknown and EK Bridge keys, 403 for forwarded requests, 421 for a foreign `Host`; the endpoint and key files' contents and modes; schema refusals with field paths; every tool's paths, including approve, deny, timeout then `get_memory_request`, single use, `policy_changed`, another agent's request, suggestions queued, saved and refused (secrets, unknown categories, bad dates, oversize metadata, above the ceiling), `open_in_funes`, and asking for more access; paused Funes, paused, expired, rotated and removed agents; withheld memory ids never in Activity; the rate limits (3 pending requests per agent under concurrency, the call burst, the write burst); quitting with a panel open (`run_quit`); and the response size and id-cap limits (`run_response_size`). |
| Remote Access harness (`Tests/mcp/remote_test.py`) | Drives the same test server's remote listener (the public origin `https://remote.test` faked through `Host`, as a tunnel forwards it) and a fake sign-in approver: 404 outside the secret path, 421 for a foreign `Host`, 403 for `Origin`; a local key refused remotely and remote and OAuth credentials refused locally; tunnel headers still 403 on the local port; cloud access off and removed agents get 401; Reset Remote Token; the remote key file's mode; pairing closed shows nothing; pairing only for an agent with cloud access; dynamic registration, the code page, code exchange, refresh rotation, reuse revoking the connection, **Revoke**, Reset Path and cloud access off disconnecting apps, Deny; turning Remote Access off. **The same decision, local vs remote:** seven agents with a local key and a remote token make the same requests through both listeners, and the results are compared field by field (status, reason, withheld counts, items, token estimates; not ids): each gate denial, shared without asking, approve, deny, timeout then `get_memory_request`, suggestions queued and saved, one pending list per agent, and the rate limits shared by both listeners with the stricter remote bucket on top. `RemoteSameInputsTests` checks in Swift that the pipeline gives retrieval and FunesCore the same inputs, and writes the same Activity rows, `via` aside. |
| App builds | An unsigned Debug build of the Mac app and the launcher, the UI-review build (`FUNES_UI_REVIEW`), and an unsigned Debug build of the iPhone app and its extensions, for a generic device, all compile. |
| String catalogs | `CHECK=1 sh scripts/sync_strings.sh`: every user-facing string is in its target's catalog: `Apps/FunesMac`, `Apps/FunesiOS`, `Apps/FunesShareExtension`, `Apps/FunesIntents` and `Apps/FunesNotifications`, each `Localizable.xcstrings`. |

Regenerate golden files after an intended change with `UPDATE_GOLDENS=1 sh scripts/test.sh`, and review the diff.

**Not in `test.sh`:** the screenshots (`sh scripts/ui_snapshots.sh`, which needs a logged-in GUI session and Screen Recording permission for the terminal, and writes light and dark PNGs of every screen, sheet and panel to `build/ui-snapshots` from fake data), and the generic protocol checks (protocol eras, statuses, slow clients, the failed-auth lockout, the launcher's listener check), which live in [BridgeKit](https://github.com/bereciartua/bridgekit)'s own test suite.

<!-- TODO(check): the testing strategy lists a launcher harness (launcher_test.py) and XCTest UI tests for Funes; neither exists in this repo yet. The launcher is covered by BridgeKit's harness. -->

## Live checks so far

These ran on the development Mac, an M1 MacBook (8 GB) with macOS 27.0.1, against Debug builds and synthetic data. Full numbers and methods are in [spike results](../spec/plans/spike-results.md).

| Date | Check | Result |
| --- | --- | --- |
| 16 Oct 2026 | **Search with Apple's embeddings** (Xcode 27.0, Swift 6.4, GRDB 7.11.1; 200 memories, 30 tasks; latency at 10,000 memories) | Fast (18 ms p50) but recall@5 only 0.58. Rejected as the default ([Spike 2](../spec/plans/spike-results.md#spike-2-search-quality-and-speed)). |
| 16 Oct 2026 | **Local open embedding models** (bge-small, e5, multilingual-e5, nomic, Qwen3; PyTorch 2.14.1 and Core ML) | bge-small-en-v1.5 as Core ML on the CPU: recall@5 0.94 with agent keywords, 10.5 ms per search end to end at 10,000 memories. Chosen ([Spike 2b](../spec/plans/spike-results.md#spike-2b-local-open-source-embeddings), ADR-0016). |
| 16 Oct 2026 | **Search re-measured inside FunesCore** with the shipped int8 model | Recall@5 0.939 with keywords, 0.689 without; keyword-only 0.828. The tokenizer matched Hugging Face on all 268 fixture texts. Keyword floor 0.15 chosen. These are the regression baselines above. |
| 16 Oct 2026 | **Agent timeouts** with a throwaway stdio server: Claude Code 2.1.288 and Codex CLI 0.160.0, headless | Neither timed out at 45 s (Claude Code ≥ 300 s, Codex ≥ 90 s measured). Both relayed "Waiting for your approval in Funes." and waited about a minute before checking back; neither retried a call on its own ([Spike 3](../spec/plans/spike-results.md#spike-3-agent-timeouts-and-the-in-call-approval)). |
| 17 Oct 2026 | **Agents on the real MCP server**: Debug build, a development vault (`FUNES_DATA_DIR`, `--dev-seed`), Claude Code 2.1.288 and Codex CLI headless with per-run configs | `funes-mcp check` passed (key file 0600, key accepted, 5 tools, Funes Vault on). Claude Code and Codex connected through the launcher. Codex saw the Share panel time out after 45 s and relayed the message. Approve, deny, and timeout then `get_memory_request` worked with Claude Code (the timeout returned at 45.1 s). A suggest-only agent's suggestion was queued with its Save panel. Both agents sent `keywords` unprompted. A timer drift (45 s ran to about 47 s) was found and fixed. |
| 17 Oct 2026 | **The panels by hand**, in the real app (Debug build `1dad5fb`, a test vault): Claude Code, Claude Desktop and Cursor | Share and Deny worked with Claude Code, and the Save panel showed. Claude Desktop and Cursor sent `keywords` and waited the full 45 s. The panels' look in light and dark was checked. |

Apart from the [Remote Access check](#remote-access-live-check) (the notarized 0.1.2 on the user's own vault), no live check so far used a signed, notarized build, the launcher from an installed app, or a real vault.

## Release rehearsals

| Date | Commit | Command | Result |
| --- | --- | --- | --- |
| 17 Oct 2026 | `c4ca516` (+ a rehearsal-only commit with a throwaway Sparkle key, because Funes's own key didn't exist yet) | `FUNES_NOTARY_PROFILE=ekbridge FUNES_SPARKLE_KEY_FILE=<throwaway> sh scripts/release.sh --untagged --no-release`, Xcode 27.0, macOS 27 | `test.sh` green; universal archive and Developer ID export; `check_bundle.sh` passed (arm64 + x86_64, `funes-mcp` as `com.funesvault.mac.mcp`, no `get-task-allow`, the pinned model inside); app and DMG notarization **Accepted** and stapled; `spctl`: `accepted, source=Notarized Developer ID` for both; `verify-update-signature`: the zip matches `SUPublicEDKey`; `appcast.xml` written. Repeated below with Funes's own key. |
| 17 Oct 2026 | `db12801` (Funes's own `SUPublicEDKey`) | `FUNES_NOTARY_PROFILE=ekbridge FUNES_SPARKLE_KEYCHAIN=1 sh scripts/release.sh --untagged --no-release`, Xcode 27.0, macOS 27 | `test.sh` green; `check_bundle.sh` passed, now with the feed and key required; app and DMG notarization **Accepted** and stapled; `spctl`: `accepted, source=Notarized Developer ID` for both; the zip signed from the login keychain (account `funes-vault`) and `verify-update-signature` matches the app's `SUPublicEDKey`; `appcast.xml` written. |
| 19 Oct 2026 | `38fa24f` (tag `v0.1.2`, build 3) | The **Release** workflow on the tag (as for `v0.1.0` and `v0.1.1` before it) | Green; the draft was published as the first Latest release, installed from GitHub over an existing install, and used for the [Remote Access check](#remote-access-live-check). |

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

## Remote Access live check

Phase 4b's live check (task 4b.15): cloud agents through Tailscale Funnel (port 443 shared by path, forwarding to 47627), run on the notarized 0.1.2. The procedure (a Debug build and a development vault, for the wait measurement) is in [spike results](../spec/plans/spike-results.md#phase-4b-live-check-cloud-agents-through-remote-access). Record each result with the date and app version.

First run on 19 Oct 2026, as reported by the user:
- the notarized 0.1.2 draft (build 3), on the user's own vault rather than a development vault;
- Tailscale Funnel on 443 shared by path, beside EK Bridge 0.11.4's `/` entry.

Empty cells weren't checked yet. EK Bridge's own claude.ai and ChatGPT connectors kept working, and Reset Path…'s move commands worked.

| Check | claude.ai | ChatGPT | Anthropic API (remote token) |
| --- | --- | --- | --- |
| Connect: pair (codes match, Allow), or paste the remote token | ✓ 19 Oct, 0.1.2 | ✓ 19 Oct, 0.1.2 | |
| `list_memory_categories` | | | |
| `request_memory`, approved in the panel (memories read) | ✓ 19 Oct, 0.1.2 | ✓ 19 Oct, 0.1.2 | |
| `request_memory`, denied | | | |
| `request_memory`, no answer: what the app does, then `get_memory_request` | | | |
| `suggest_memory` → queued, in the Inbox | ✓ 19 Oct, 0.1.2 | ✓ 19 Oct, 0.1.2 | |
| **Revoke** (OAuth) or **Reset Remote Token…** (token): the old credential fails | | | |
| **Turn Off Remote Access**: the URL stops answering | | | |
| How long it waits for a tool call | | | — |
| Sends `keywords` | | | |

Agent versions: claude.ai and ChatGPT on the web, as of that date; Tailscale 1.102.4. App version: 0.1.2 (build 3), the notarized draft. Date: 19 Oct 2026.

## Release install test

Before the first public release, and after any change to the bundle layout, signing or the updater. Record the date, macOS version, architecture and app version.

- [ ] Download `FunesVault.dmg` from the draft release in Safari, so it carries the quarantine flag.
- [ ] Open it: no Gatekeeper warning. `spctl --assess --type open --context context:primary-signature -v FunesVault.dmg` says `source=Notarized Developer ID`.
- [ ] Drag the app to Applications and open it: no warning; the menu bar icon appears and the window opens on Home with the setup checklist.
- [ ] `sh scripts/check_bundle.sh /Applications/FunesVault.app arm64 x86_64` passes: both architectures, `funes-mcp` signed as `com.funesvault.mac.mcp` by the same team, the hardened runtime, Sparkle's feed and key, the bundled model's checksums, and the licence files.
- [ ] Vault search finds a memory by meaning, not just by its words (the model loaded).
- [ ] Add one agent, connect it with one click, and run `funes-mcp check` against it.
- [ ] `lsof -nP -iTCP -sTCP:LISTEN` shows Funes Vault only on `127.0.0.1:47625` (Remote Access off; with it on, also `127.0.0.1:47627`). No firewall or Local Network prompt while iPhone access is off; turning it on (Same Wi-Fi) adds `*:47626` and macOS asks for Local Network access.
- [ ] Settings ▸ General ▸ Updates shows that the app can update itself, and **Check Now** reaches the feed.
- [ ] `brew install --cask bereciartua/tap/funes-vault` on a Mac without the app installs the same version.
- [ ] If an Intel Mac is available, repeat the first five steps there.

Partial run: on 19 Oct 2026 the notarized 0.1.2 (build 3) was installed from GitHub over an existing install and used for the Remote Access check. The steps above weren't recorded.

## Fresh-account test

On a new macOS user account (or a macOS VM), with no agents' configs and no Funes data:

- [ ] Install from the DMG and open the app. The setup checklist shows the four steps; **Found on this Mac** lists only agents that are installed.
- [ ] **Connect an agent ▸ Add…**: add Claude Code (or another installed agent) with the default starting access and **Add and Connect…**. The preview shows the exact change; the backup is written next to the config; the key isn't in it. The Connect tab suggests a first question.
- [ ] Answer the seed questions, and import a sample ChatGPT memories file: the answers and imports land in the Inbox; a secret in the file is reported and not imported. A category ticked under "Which of these should agents never see?" is Deny for the agent, nothing from that step reaches the Inbox, and an agent added afterwards starts with Deny for it.
- [ ] **Your plans** (Settings ▸ AI ▸ Models & Accounts): with Claude Code and Codex installed, each shows "Signed in to …" (or the sign-in command); Test Connection works; choosing one for New memories shows the subscription disclosure line. Before a release that touches the adapters: `FUNES_LIVE_SUBSCRIPTIONS=1 swift test --package-path Packages/FunesCore --filter liveSmokeTest`.
- [ ] **Daily tidy-up** (Settings ▸ AI ▸ Features): before the first run it shows "About N memories to check…"; **Tidy Up Now** with no provider (or Apple on-device) finds only exact copies and expired memories; with a local server or cloud model, two memories where one replaced the other give an archive card ("Keeps …"), two that say parts of one thing a merge card with what each kept, and two that disagree a conflict with **Keep This**, **Both Are True** and **Edit…**. Rejecting a card and running again doesn't ask again; editing one of its memories first drops the card and asks again. With **Apply changes automatically** at Duplicates only and Claude Haiku or Opus, a copy is archived and listed in **Applied automatically**; **Undo** brings it back. A run with results posts "Funes applied … and has … for you to review." The iPhone shows tidy-up cards as "Review on your Mac". With the tidy-up on and the Mac asleep at the chosen time, the run happens at wake.
- [ ] With a local server or cloud model chosen and **Split into separate memories** on: a capture with three facts becomes one card of three pieces with badges; one that repeats or updates a memory says Already saved or Updates *it*; **Keep as One** restores the capture; while it's being split the card shows **Processing…** with why it waits (Splitting with *provider*…, *N* ahead of it), can't be applied or edited and is skipped by bulk Apply, but Reject works and cancels it; with the provider unreachable it ends as **Couldn't split** with **Try Again** and **Keep as One**; an agent's suggestion with Ask before saving shows its Save panels only once it's split, one per piece; on the iPhone a processing card is a greyed **Processing…** row that can only be rejected, and a failed one offers **Try Again** and **Keep as One**; an agent's suggestion in a category it can't save to shows Outside *agent*'s scope and Apply All skips it; an import offers **Import Without Splitting** with the request estimate. With splitting off, captures behave as in v0.2.
- [ ] Apply some suggestions; Vault search finds them.
- [ ] Ask the agent something that needs a Low memory: the Share panel says where the text goes and ticks only strong matches; **Share** delivers it, and Activity records it by id. Ask again from another app and press ⌃⌥⌘R: the panel comes forward and Return answers it; **More Time** moves it to Pending requests.
- [ ] Capture with ⌥⌘M; the card gets a proposed title and categories.
- [ ] **Home:** type a memory and press Return: "Saved to Inbox", and it's in the Inbox; a pasted API key shows the secret-scanner error and isn't saved; ⌘Return opens the Vault searching for the text. On macOS 26 or later, the mic asks for microphone and speech recognition access the first time and dictates into the field (in Home and the ⌥⌘M box); on macOS 15 there's no mic. The pulse shows the day's numbers on hover, a click opens that day in Activity and a refused dot its Problems; the cards open the Vault (newest first, a sensitivity), Activity and an agent's Activity tab.
- [ ] `~/Library/Application Support/FunesVault/` is mode 0700, its files 0600, and `agent-keys/` holds one key file.
- [ ] Quit: `mcp-endpoint.json` is gone.

<!-- TODO(check): no results recorded yet. -->

## Update test

**To do:** a Sparkle update from 0.1.2, the first public (Latest) release, to the next release, through the published `appcast.xml`.

- [ ] The installed, notarized 0.1.2 reads the published feed; **Check for Updates…** offers the next release with its release notes.
- [ ] Installing takes a click, replaces the app in `/Applications` and relaunches it as the new version, signed by the same team.
- [ ] With a request waiting in Pending requests, the relaunch waits until it's answered or expires.
- [ ] After the update: the vault, agents, keys, Activity and settings are unchanged; each connected agent reconnects without a setup change; `funes-mcp check` passes.

<!-- TODO(check): EK Bridge has scripts/update_test.sh (two local builds and a local feed); there's no Funes equivalent in scripts/ yet. Its builds must be signed with the Developer ID: other builds never check (SparkleUpdater.isConfigured). -->
