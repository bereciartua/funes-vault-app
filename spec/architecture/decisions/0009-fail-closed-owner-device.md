# ADR-0009: Fail-closed agent access; owner devices skip approvals

**Status:** Accepted · 2026-10-16

**Context.** The web code denied only missing or blocked clients, while its docs promised "unknown clients fail closed". Paired iPhones represent the user.

**Decision.**

- New agents start with **no access**.
- Paused, expired, removed or unknown agents are refused with explicit reason codes.
- Paired owner devices act as the user: no ceilings, categories or panels. They're still authenticated per message, rate-limited, logged and revocable.

**Consequences.**

- No ambiguity between docs and code.
- A stolen, still-paired phone has full access until it's revoked. Mitigated by Secure Enclave keys and one-click revocation, and documented.

**Alternatives considered.**

- **Treat the phone as an agent with access settings:** adds friction for the owner, no real security gain.
