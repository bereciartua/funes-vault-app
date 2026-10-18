# Phase 4: Ship the Mac public preview (v0.1)

**Goal:** a notarized, auto-updating public preview that people can install with one command.

**Duration:** 1 weekend (+ a buffer weekend). **Depends on:** Phase 3.

## Tasks
### 4.1 Release pipeline · 3 h
- [x] `scripts/release.sh` adapted from EK Bridge:
  1. clean tree tagged `v<version>`;
  2. tests;
  3. `xcodebuild archive` (universal);
  4. export with Developer ID;
  5. notarize and staple;
  6. DMG (`make_dmg.sh` + `dmg_window.swift`), notarized and stapled;
  7. zip for Sparkle;
  8. `SHA256SUMS`;
  9. Sparkle `sign_update` + `verify_update_signature`;
  10. `appcast.xml`;
  11. draft GitHub release.

  Also `--untagged --no-release` rehearsals, `scripts/check_bundle.sh` (both architectures, `funes-mcp` signed as `com.funesvault.mac.mcp`, no `get-task-allow` anywhere, the pinned model inside, licenses) and the **Embed Resources** build phase (`scripts/embed_resources.sh`), which puts the bundled model and the license files in every build and fails a Release build without the model. Archives are signed manually with the Developer ID identity and exported with method `developer-id`. See [MAINTAINING](../../docs/MAINTAINING.md#releasing).
- [x] `.github/workflows/release.yml`: protected environment, temporary keychain, notary key, Sparkle key, build provenance attestation.
- [x] `ci.yml`: `swift test` on the packages, `xcodebuild test`, the Python MCP harness, golden fixtures. Already covered by `scripts/test.sh`, which CI runs (there is no XCTest target in the app yet; UI is checked with `scripts/ui_snapshots.sh`). Its cost-saving triggers are unchanged.

### 4.2 Distribution · 2 h
- [ ] Homebrew: add `Casks/funes-vault.rb` to `bereciartua/homebrew-tap`, with the update workflow checking the attestation and SHA-256 (EK Bridge pattern). **Prepared:** the cask and a patch for the tap in [`packaging/homebrew/`](../../packaging/homebrew/README.md), to apply once v0.1.0 is published and the repo is public.
- [x] MCP Registry: `server.json` (`com.funesvault/funes`), plus the `mcp-registry.yml` workflow. It signs in with `mcp-publisher login dns` (GitHub OIDC only covers `io.github.*` names): the secret `MCP_REGISTRY_DNS_KEY` and a TXT record on funesvault.com ([site/DNS.md](../../site/DNS.md)).
- [ ] Listings: mcpservers.org, glama.ai (`glama.json`). `glama.json` is ready; the submissions happen at launch.

### 4.2b Website on funesvault.com · 2 h
- [x] A static site (GitHub Pages from the repo's `site/` folder, or similar) with HTTPS: landing page, download (latest DMG), Homebrew command, docs links, `/privacy` and `/support`. Deployed by `.github/workflows/pages.yml` once Pages is enabled (source: GitHub Actions).
- [ ] DNS: a TXT record for MCP Registry namespace verification (`com.funesvault`); optional redirect from `funesvault.app`. The records to add are in [site/DNS.md](../../site/DNS.md).
- [ ] Email forwarding for `support@funesvault.com` and `security@funesvault.com`, referenced in `SECURITY.md` and the App Store record.

### 4.3 Docs · 3 h
- [x] `README.md`: hero, screenshots (light and dark), get started, how you stay in control, FAQ, security boundary. Structure after EK Bridge's README.
- [x] `docs/ARCHITECTURE.md`, `docs/MCP.md` (agent setups, tools, limits), `docs/TESTING.md` (evidence ledger, live matrix), `docs/MAINTAINING.md`, `SECURITY.md`, `CHANGELOG.md`, `CONTRIBUTING.md`.
- [x] Privacy statement: everything that leaves the Mac ([PRIVACY.md](../../PRIVACY.md), and `/privacy` on the site).

### 4.4 Live test matrix · 2 h
- [ ] Claude Code, Claude Desktop, Cursor, Codex: connect, request (approve, deny, timeout then get), suggest (queued and saved), paused agent, removed agent.
- [ ] Record the results in `docs/TESTING.md`.

### 4.5 Launch · 1 h
- [ ] Publish the release (from draft), check that Sparkle sees it, check `brew install --cask bereciartua/tap/funes-vault`.
- [ ] Mention it in EK Bridge's README and release notes ("From the maker of EK Bridge: Funes gives agents your memory, not all of it.").
- [ ] Optional: a Show HN and an r/macapps post. These are self-serve channels; no outreach required.

## Exit criteria
- **v0.1.0 is public:**
  - the DMG is notarized;
  - the Homebrew cask works;
  - the MCP Registry is listed;
  - a Sparkle update from v0.1.0 to v0.1.1 has been tested.
- The live matrix is recorded for 4 agents.
