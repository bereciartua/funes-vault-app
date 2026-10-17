# Changelog

Notable changes to Funes Vault, newest first, in the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. Versions follow `MARKETING_VERSION` in the Xcode project. Release notes come from this file.

## [Unreleased]

### Added

- Repository setup: the product definition in `spec/`, the `FunesProtocol` and `FunesCore` Swift packages, the `FunesVault` Xcode project with a placeholder menu bar app, and CI.
- The vault logic in `FunesCore` (Phase 1, no UI yet): the SQLite store, hybrid search with the bundled bge-small embedding model (`scripts/fetch_embedding_model.sh`), the access policy with approvals and single-use delivery, suggestions, captures, agents and keys, AI model providers with cloud guardrails, and import and export. The secret scanner lives in `FunesProtocol`.
- Agents can connect (Phase 2, no main window yet). The app opens the vault and serves MCP on `127.0.0.1:47625`, and agents reach it through the `funes-mcp` launcher inside the app. They can list categories, request memories, check a waiting request and suggest memories. A floating panel asks before sharing, with a checkbox per memory and a 45-second countdown, and another asks whether to save a suggestion. The menu shows whether agents can connect and can pause Funes Vault. The protocol and security core is [BridgeKit](https://github.com/bereciartua/bridgekit), shared with EK Bridge.
- The Mac app shell (Phase 3): the menu bar icon shows when Funes needs you or is paused, and its menu has Remember…, the Inbox count, Pending requests with minutes left, Pause Funes Vault (for 1 hour, until tomorrow or until you resume, kept across relaunches), Open Funes Vault and Settings. The main window has Vault, Inbox, Agents and Activity; Settings opens at login on request and can show Funes in the Dock. Run from Downloads or a disk image, it offers to move itself to Applications.
- The Vault: search as you type, filters by category, kind, sensitivity, status and source, and three sort orders. Each memory opens in an editor with a character counter, categories, a sensitivity level with what it means, an optional expiry date, how often it was shared (linking to Activity), its history, and Archive, Delete and Still True. Recently Deleted keeps memories 30 days with Restore and Delete Now. Select several to archive, delete, move or change their sensitivity together. Categories can be renamed, and your own added or deleted. Saving a memory says when a similar one exists.
