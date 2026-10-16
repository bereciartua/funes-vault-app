# ADR-0011: App-layer end-to-end encryption for companion traffic (HPKE + P-256 Secure Enclave signing)

**Status:** Proposed (validate in Spike 1) · 2026-10-16

**Context.** The iPhone reaches the Mac over the LAN, Tailscale or a public tunnel. Some tunnels (Cloudflare) end TLS at the provider. The phone acts with owner-level access.

**Decision.**

- Every request is sealed with **HPKE** (`P256_SHA256_AES_GCM_256`) to the Mac's key and **signed** with the device's P-256 key (Secure Enclave when available), with a timestamp and nonce for replay protection.
- Responses are AES-GCM encrypted with a key exported from the request's HPKE context.
- Pairing uses a QR code (Mac public keys plus a single-use secret) and an Allow prompt on the Mac.
- The transport is plain HTTP on the LAN and Tailscale, and HTTPS through tunnels.

**Consequences.**

- Confidentiality and integrity no matter which network path is used, including tunnel providers.
- Custom protocol code needs careful tests and fuzzing. Mitigated by using CryptoKit primitives only and keeping the envelope small.
- Some metadata stays visible on the LAN.

**Alternatives considered.**

- **Mutual TLS with pinned certificates:** good on the LAN, but doesn't survive TLS-terminating tunnels.
- **Noise protocol:** good, but needs a third-party library.
