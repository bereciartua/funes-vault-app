# Changelog

Notable changes to Funes Vault, newest first, in the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. Versions follow `MARKETING_VERSION` in the Xcode project. Release notes come from this file.

## [Unreleased]

### Added

- Repository setup: the product definition in `spec/`, the `FunesProtocol` and `FunesCore` Swift packages, the `FunesVault` Xcode project with a placeholder menu bar app, and CI.
- The vault logic in `FunesCore` (Phase 1, no UI yet): the SQLite store, hybrid search with the bundled bge-small embedding model (`scripts/fetch_embedding_model.sh`), the access policy with approvals and single-use delivery, suggestions, captures, agents and keys, AI model providers with cloud guardrails, and import and export. The secret scanner lives in `FunesProtocol`.
