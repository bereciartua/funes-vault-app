# Release and distribution

## Versioning
- **SemVer.** The Mac and iPhone apps share a version series (the iPhone ships from 0.2.0).
  - `0.x` = public preview; minor releases may change behaviour, documented in CHANGELOG.
  - 1.0 is declared when both apps have been stable for 2 months with external users.
- **Build numbers** increase monotonically across all builds (`CFBundleVersion`).
- **Contract versions** are tracked separately:
  - the MCP tool contract (fixture version);
  - the companion protocol (`v` in envelopes);
  - the export format (`funesvault.export.v1`);
  - the database schema (migrations).

  Breaking any of them needs a CHANGELOG "Breaking" note and, for the companion protocol, a period in which both versions are supported.
- **BridgeKit** has its own SemVer tags (0.x for now; a breaking change bumps the minor version). Both apps pin an exact version. Release order:
  1. Tag BridgeKit.
  2. Bump EK Bridge; its fixtures and harnesses must stay unchanged and green.
  3. Bump Funes.

## Mac channels
| Channel | How | Notes |
|---|---|---|
| GitHub Releases | `EKBridge.dmg`-style stable name `FunesVault.dmg` + versioned assets, `SHA256SUMS`, `appcast.xml` | Draft → publish manually |
| Sparkle updates | `releases/latest/download/appcast.xml` | Only published, non-prerelease releases are offered; click to install |
| Homebrew | `brew install --cask bereciartua/tap/funes-vault` | The tap's workflow verifies the attestation and SHA-256 before bumping |
| MCP Registry | `com.funesvault/funes` | Published by a workflow on release |
| Directories | mcpservers.org, glama.ai | Badges in the README |

## iPhone channel
- **TestFlight** (internal, then external), then the **App Store**. Free. No in-app purchases in v0.2 (pricing is an open question).
- **App Review risk:** the app needs a Mac to be useful. Mitigations:
  - a demo mode;
  - clear review notes;
  - a screen recording of pairing in the notes.

## Release checklist
1. CHANGELOG updated; version bumped in all targets; `server.json` version matches.
2. `test.sh` (or `xcodebuild test` + Python harnesses) green; golden fixtures unchanged, or their changes intended.
3. UI snapshots reviewed (light and dark).
4. Live matrix run for the agents (and the iPhone transport matrix if the companion changed). Results in `docs/TESTING.md`.
5. Tag `vX.Y.Z`, then the CI release workflow builds, notarizes, signs the update and drafts the release.
6. Download the draft DMG on a clean user account: install, first run, connect one agent.
7. Publish the release, then confirm that:
   - the Sparkle update is offered to the previous version;
   - the Homebrew bump PR is merged;
   - the MCP Registry is updated.
8. iPhone (when changed): archive, upload, TestFlight smoke test, submit for review.

## Support
Best-effort, public-preview support through GitHub Issues, with templates for bugs and feature requests. `SECURITY.md` has a private reporting channel (GitHub private vulnerability reporting).
