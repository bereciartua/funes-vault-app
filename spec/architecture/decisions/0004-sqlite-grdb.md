# ADR-0004: SQLite through GRDB for storage

**Status:** Accepted · 2026-10-16

**Context.** Disclosure, suggestion-apply and import flows need real transactions, row-level consistency and SQL migrations. Search needs FTS5.

**Decision.**

Use SQLite in WAL mode through **GRDB** (MIT): a `DatabasePool`, `DatabaseMigrator`, FTS5, and online backups.

**Consequences.**

- Explicit transactions, testable migrations, and concurrent fast reads.
- One more third-party dependency, besides Sparkle. GRDB is mature and widely used.
- No automatic sync, which is fine given ADR-0003.

**Alternatives considered.**

- **SwiftData:** less control over transactions and migrations, opaque.
- **Core Data:** heavier, and no FTS5.
- **JSON files like EK Bridge's registry:** fine for small settings, not for a searchable vault.
