# Phase 4: Ship the Mac public preview (v0.1)

**Goal:** a notarized, auto-updating public preview that people can install with one command.

**Duration:** 1 weekend (+ a buffer weekend). **Depends on:** Phase 3.

## Tasks
### 4.1 Release pipeline · 3 h
- [ ] `scripts/release.sh` adapted from EK Bridge:
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
- [ ] `.github/workflows/release.yml`: protected environment, temporary keychain, notary key, Sparkle key, build provenance attestation.
- [ ] `ci.yml`: `swift test` on the packages, `xcodebuild test`, the Python MCP harness, golden fixtures.

### 4.2 Distribution · 2 h
- [ ] Homebrew: add `Casks/funes-vault.rb` to `bereciartua/homebrew-tap`, with the update workflow checking the attestation and SHA-256 (EK Bridge pattern).
- [ ] MCP Registry: `server.json` (`com.funesvault/funes`), plus the `mcp-registry.yml` workflow with OIDC.
- [ ] Listings: mcpservers.org, glama.ai (`glama.json`).

### 4.2b Website on funesvault.com · 2 h
- [ ] A static site (GitHub Pages from the repo's `site/` folder, or similar) with HTTPS: landing page, download (latest DMG), Homebrew command, docs links, `/privacy` and `/support`.
- [ ] DNS: a TXT record for MCP Registry namespace verification (`com.funesvault`); optional redirect from `funesvault.app`.
- [ ] Email forwarding for `support@funesvault.com` and `security@funesvault.com`, referenced in `SECURITY.md` and the App Store record.

### 4.3 Docs · 3 h
- [ ] `README.md`: hero, screenshots (light and dark), get started, how you stay in control, FAQ, security boundary. Structure after EK Bridge's README.
- [ ] `docs/ARCHITECTURE.md`, `docs/MCP.md` (agent setups, tools, limits), `docs/TESTING.md` (evidence ledger, live matrix), `docs/MAINTAINING.md`, `SECURITY.md`, `CHANGELOG.md`, `CONTRIBUTING.md`.
- [ ] Privacy statement: everything that leaves the Mac.

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
