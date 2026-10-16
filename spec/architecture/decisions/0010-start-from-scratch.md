# ADR-0010: Start from scratch; Funes Vault (web) is reference only

**Status:** Accepted · 2026-10-16

**Context.** Nobody uses the web version, so there's no data or setup to migrate. It may keep existing for now and may eventually be replaced by the native app.

**Decision.**

The native Funes Vault is designed fresh: data model, tool names and schemas, and export format (`funesvault.export.v1`). The web version's rule order, reason codes, privacy guarantees, input limits, default categories, seed questions and secret patterns are **carried over as reference**, not as compatibility constraints. No migration or import from the web export.

**Consequences.**

- Freedom to simplify: no review state on memories, no unused operations, privacy fixes (withheld counts instead of ids).
- **Repositories (decided 2026-10-16):** the native app gets a **new repo**, `bereciartua/funes-vault-app`. `bereciartua/funes-vault` stays as a **historical artifact**, not archived or deleted.
- **Once the native app is production-ready (1.0),** add a note at the top of `funes-vault`'s README saying it's no longer maintained, with a link to the new repo.

**Alternatives considered.**

- **Port the web schema and tools for compatibility:** unnecessary without users.
