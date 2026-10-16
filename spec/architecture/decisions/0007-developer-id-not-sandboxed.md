# ADR-0007: Developer ID distribution, not sandboxed (Mac); App Store (iPhone)

**Status:** Accepted · 2026-10-16

**Context.** Funes writes other apps' MCP config files (with a backup), runs agent CLIs (`claude mcp add-json`), inspects processes (the launcher's `libproc` check) and listens on local ports. EK Bridge is unsandboxed for the same reasons.

**Decision.**

The Mac app is distributed **outside the Mac App Store** with Developer ID, notarization and the hardened runtime, **not sandboxed**. The iPhone app ships through the **App Store**, with TestFlight first.

**Consequences.**

- One-click agent setup and launcher verification work as in EK Bridge.
- No Mac App Store discovery. The channels are Homebrew, the MCP Registry, GitHub and the website.
- The App Store reviews the iPhone app, which needs a demo mode because review can't pair with a Mac.

**Alternatives considered.**

- **A sandboxed Mac App Store app:** blocks config writing and process checks. It could ship later as a reduced "Lite" build, if ever.
