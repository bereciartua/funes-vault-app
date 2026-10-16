# ADR-0008: Copy EK Bridge components now, extract BridgeKit later

**Status:** Superseded by [ADR-0013](0013-shared-bridgekit-core.md) · 2026-10-16 (originally accepted the same day)

**Context.** About 14K lines of EK Bridge are generic: the MCP server, launcher, approvals, activity, agent setup, updates and Remote Access. Extracting them into a shared package first would destabilize EK Bridge while Funes's needs are still unknown.

**Decision.**

Copy the generic files into `Funes/Packages/BridgeKit`, parameterized for Funes. After Funes v0.1 ships, extract BridgeKit into its own repo and move EK Bridge onto it gradually.

**Consequences.**

- Fast start, and EK Bridge stays stable.
- The two copies drift until extraction. Mitigation: record the source EK Bridge commit for every copied file in `BridgeKit/PROVENANCE.md`, and diff periodically.

**Alternatives considered.**

- **Extract first:** a slower start, risk to EK Bridge.
- **Never share:** permanent duplication.
