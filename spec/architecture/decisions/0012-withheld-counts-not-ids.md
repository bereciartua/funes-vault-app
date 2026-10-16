# ADR-0012: Denials report withheld counts, not memory ids

**Status:** Accepted · 2026-10-16

**Context.** The web version returned `denied: [{memoryId, reason}]` to agents, revealing that specific memories exist.

**Decision.**

Responses include `withheld: {reason: count}` only. `not_found` is returned the same way for missing and forbidden objects, and categories are listed without counts.

**Consequences.**

- Agents learn less about the vault's contents.
- Agents get slightly less precise feedback. The `message` field suggests asking the user to adjust access.

**Alternatives considered.**

- **Keep the web behaviour:** leaks existence and sensitivity of memories.
