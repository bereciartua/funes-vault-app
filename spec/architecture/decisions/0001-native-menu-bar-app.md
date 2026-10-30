# ADR-0001: Native macOS menu bar app

**Status:** Accepted · 2026-10-16 · **Amended by** [ADR-0029](0029-menu-bar-panel.md) (the icon opens a panel; a right click shows a short menu)

**Context.** The web version (Funes Vault) needs Node, pnpm, Docker, Postgres, Redis, a background worker, Caddy, three HTTPS origins, Google sign-in and OpenAI keys. In practice nobody can install it. EK Bridge showed that a notarized menu bar app with a local MCP server is easy to install and use.

**Decision.**

Build Funes as a **native macOS menu bar app** (Swift, SwiftUI hosted in AppKit, `LSUIElement`), distributed as a notarized DMG and a Homebrew cask, with Sparkle updates.

**Consequences.**

- Installation is a download or `brew install --cask`, with nothing else to run.
- The vault can be local, and it's always on while the Mac is on.
- Mac-only: no Windows, Linux or web. This is accepted, since the audience is Mac-based AI-agent users.
- Native panels (non-activating `NSPanel`) give a good approval UX.

**Alternatives considered.**

- **Keep the web app, packaged with Docker:** still too heavy.
- **Electron or Tauri:** cross-platform, but a heavier runtime, a weaker native panel experience, and no reuse of EK Bridge.
- **CLI only:** no approval UI.
