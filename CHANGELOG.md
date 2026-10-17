# Changelog

Notable changes to Funes Vault, newest first, in the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. Versions follow `MARKETING_VERSION` in the Xcode project. Release notes come from this file.

## [Unreleased]

### Added

- Repository setup: the product definition in `spec/`, the `FunesProtocol` and `FunesCore` Swift packages, the `FunesVault` Xcode project with a placeholder menu bar app, and CI.
- The vault logic in `FunesCore` (Phase 1, no UI yet): the SQLite store, hybrid search with the bundled bge-small embedding model (`scripts/fetch_embedding_model.sh`), the access policy with approvals and single-use delivery, suggestions, captures, agents and keys, AI model providers with cloud guardrails, and import and export. The secret scanner lives in `FunesProtocol`.
- Agents can connect (Phase 2, no main window yet). The app opens the vault and serves MCP on `127.0.0.1:47625`, and agents reach it through the `funes-mcp` launcher inside the app. They can list categories, request memories, check a waiting request and suggest memories. A floating panel asks before sharing, with a checkbox per memory and a 45-second countdown, and another asks whether to save a suggestion. The menu shows whether agents can connect and can pause Funes Vault. The protocol and security core is [BridgeKit](https://github.com/bereciartua/bridgekit), shared with EK Bridge.
