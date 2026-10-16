# ADR-0003: The Mac is the only source of truth; the iPhone is a thin client (no CloudKit)

**Status:** Accepted · 2026-10-16

**Context.** An iPhone companion needs to capture memories, and ideally search and review them. Options:
- **Replication** with CloudKit sync (CKSyncEngine with encrypted fields). This was verified to work with Developer ID.
- **A thin client** that talks to the Mac.

The user prefers that the vault live only on the Mac, and accepts that search and review need the Mac to be reachable, **as long as capture always works**.

**Decision.**

No CloudKit and no replication. The iPhone is a **paired owner device** that calls a companion API on the Mac (LAN via Bonjour, then private Tailscale, then an optional public tunnel). Captures are queued on the phone and delivered exactly once.

**Consequences.**

- The strongest privacy claim: there's no cloud copy at all.
- No sync engine, no conflicts, no CloudKit entitlement or provisioning profile.
- Search and review on the phone need the Mac awake and reachable.
- Approving disclosures from the phone isn't possible without a push channel (deferred; CloudKit could later be used only as a "doorbell" with no memory data).
- Phase 0 tests the companion transport instead of CloudKit.

**Alternatives considered.**

- **CloudKit replication:** works offline, but stores data in iCloud (fully end-to-end encrypted only with Advanced Data Protection) and needs a sync engine and conflict handling.
- **Our own relay server:** contradicts "no server of ours".
