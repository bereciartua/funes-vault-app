# Companion protocol (Mac ↔ iPhone)

**Status:** design for v0.2, to be validated in [Spike 1](../plans/phase-0-spikes.md). §2–4 are implemented in `FunesProtocol/Companion` (task 5.1), with the byte-level choices in §3.1; the Spike 1 rows that need a real iPhone haven't run yet ([results](../plans/spike-results.md#spike-1-companion-transport)).

The iPhone is a **thin client** of the Mac. There is no replication and no cloud ([ADR-0003](decisions/0003-mac-is-the-only-source-of-truth.md)). Messages are **signed by the device and end-to-end encrypted at the application layer** ([ADR-0011](decisions/0011-app-layer-encryption-for-companion.md)). Neither the LAN, Tailscale nor a tunnel provider can read or forge them.

## 1. Keys
| Key | Algorithm | Where | Purpose |
|---|---|---|---|
| Mac signing key | P-256 ECDSA | Mac Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` | Signs pairing confirmations |
| Mac HPKE key | P-256 key agreement | Mac Keychain, same | Recipient of every phone request |
| Device signing key | P-256 ECDSA | iPhone **Secure Enclave** (`SecureEnclave.P256.Signing`); Keychain fallback on devices without one | Signs every request |
| Device HPKE key | P-256 key agreement | iPhone Keychain (`…ThisDeviceOnly`) | Recipient of pairing confirmations |
| Pairing secret | 32 random bytes | QR code only, valid once for 5 min | Proves the phone saw the Mac's screen |

- **Ciphersuite:** HPKE base mode, `P256_SHA256_AES_GCM_256` (CryptoKit `HPKE`, macOS 14+ / iOS 17+).
- **Why P-256 and not Ed25519:** the Secure Enclave only supports P-256. EK Bridge's CLI uses Ed25519, but it has no Secure Enclave constraint.

## 2. Pairing

### 2.1 QR payload
The QR code shown on the Mac contains base64url-encoded JSON:
```json
{"v":1,"pid":"<pairingId>","mac":"<macId>","name":"Maya's MacBook Pro",
 "sig":"<Mac signing pub, X9.63>","hpke":"<Mac HPKE pub, X9.63>",
 "sec":"<pairing secret>","exp":1792000000,
 "addr":[{"t":"lan","host":"maya-mbp.local","port":47626},
         {"t":"ts","host":"100.101.102.103","port":47626},
         {"t":"tun","url":"https://maya-mbp.tailnet.ts.net/r/<path-secret>"}]}
```
The QR code is the out-of-band trust anchor: it carries the Mac's public keys.

### 2.2 Exchange
1. **Phone:** generates its device keys and builds:
   - the transcript `T = "funes-pair-v1" ‖ pid ‖ mac ‖ devSigPub ‖ devHpkePub ‖ deviceName ‖ model`;
   - the proof `P = HMAC-SHA256(sec, T)`.
2. **Phone → Mac:** `POST /c/v1/pair`, with the body sealed to the Mac's HPKE key (`info = "funes-pair-v1"`) and containing `{pid, deviceName, model, devSigPub, devHpkePub, proof: P}`. The whole request is also signed with the device signing key.
3. **Mac** checks that:
   - the `pid` exists and hasn't expired;
   - the proof `P` is valid (constant-time comparison);
   - the device signature is valid.

   It then shows **"<deviceName> wants to pair · Allow / Deny"** on the Mac. This is a second factor, so a leaked photo of the QR code isn't enough.
4. **On Allow,** the Mac:
   - stores the Device;
   - deletes the pairing secret (single use);
   - replies sealed to the device's HPKE key with `{deviceId, mac, confirm: HMAC-SHA256(sec, "mac-confirm" ‖ T)}`, signed with the Mac signing key.
5. **Phone:** verifies the Mac signature with the public key from the QR code, and verifies `confirm`. It then stores `{macId, macSigPub, macHpkePub, deviceId, addresses}`.
6. **On Deny or timeout,** the response is `pairing_denied`. The secret is burned either way.

Limits: at most 5 paired devices, and 3 pairing attempts per pairing session.

### 2.3 Pairing envelopes
- **Phone → Mac:** `{"v":1,"ts":…,"nonce":…,"enc":…,"ct":…,"sig":…}`.
  - HPKE `info = "funes-pair-v1"`, `aad = "funes-pair-v1" ‖ v ‖ ts ‖ nonce`.
  - The signature is over `"funes-pair-req-v1" ‖ v ‖ ts ‖ nonce ‖ enc ‖ ct`, with the device signing key the sealed body carries, so the Mac opens first and then verifies.
  - `|now − ts| ≤ 120 s`, otherwise `pairing_expired`.
- **Mac → phone:** `{"v":1,"enc":…,"ct":…,"sig":…}`, sealed to the device HPKE key with `info = "funes-pair-confirm-v1"` and `aad = "funes-pair-confirm-v1" ‖ v ‖ request nonce`. Signed by the Mac over `"funes-pair-confirm-sig-v1" ‖ v ‖ request nonce ‖ enc ‖ ct`. The request nonce binds the answer to that one request.
- **Failures** are HTTP `403` with a plaintext `{"error":"<code>"}`: `pairing_expired` (unknown or expired session), `pairing_invalid` (wrong proof), `pairing_denied`, `too_many_attempts`, `too_many_devices`, `invalid_request` (malformed, unreadable or badly signed).

## 3. Request envelope (every call after pairing)
`POST /c/v1/rpc` with `Content-Type: application/funes-envelope+json`. A single endpoint, so the method name is hidden inside the ciphertext.

```json
{"v":1,"did":"<deviceId>","ts":1792000123456,"nonce":"<16B b64url>",
 "enc":"<HPKE encapsulated key b64url>","ct":"<ciphertext b64url>",
 "sig":"<ECDSA P-256 sig b64url>"}
```
- **Plaintext before sealing:** `{"id":"<call id>","method":"captures.submit","params":{…}}`.
- **HPKE seal:**
  - recipient = the Mac HPKE public key;
  - `info = "funes-companion-v1|" + did`;
  - `aad = v ‖ did ‖ ts ‖ nonce`.
- **Signature:** `ECDSA-P256-SHA256` over `"funes-req-v1" ‖ v ‖ did ‖ ts ‖ nonce ‖ enc ‖ ct`.

**Mac verification order** (every failure is `401` with a minimal plaintext error, `{"error":"<code>"}`, and no details beyond the code):
0. The body is a well-formed version-1 envelope of at most 256 KiB, with every field the right size. Otherwise `invalid_envelope`.
1. `did` is known and not revoked. Otherwise `unknown_device` or `revoked`.
2. `|now − ts| ≤ 120 s`. Otherwise `clock_skew`, and the reply includes `server_time` (milliseconds), which isn't secret.
3. The `nonce` hasn't been seen in the last 10 minutes (up to 10,000 per device). Otherwise `replay`.
4. The signature verifies with the device signing key. Otherwise `invalid_signature`. Only now is the nonce remembered, so nobody without the device key can fill the cache and push a real nonce out of it.
5. The HPKE open succeeds. Otherwise `decryption_failed`.

When a device's 10,000 slots are full, the oldest nonce is dropped and its `ts` becomes a floor: anything sent at or before it is a `replay` from then on (fail closed). The 300-calls-a-minute limit keeps a real device far below that.

### 3.1 Bytes on the wire
- **`‖`** is length-prefixed concatenation: each field is a 4-byte big-endian length, then its bytes. Strings are UTF-8 and integers 8-byte big-endian, so two field lists never give the same bytes. Each list starts with its label (`"funes-req-v1"` and so on); the request `aad` starts with `"funes-aad-v1"`.
- **Binary fields** are unpadded base64url, and only the canonical spelling is accepted.
- **Sizes:** `nonce` 16 bytes; `enc` 65 (an uncompressed P-256 point); `sig` 64, the raw `r ‖ s` form; `ct` at least the 16-byte GCM tag. Public keys are X9.63.
- **Ids:** `did` and the Mac id are lowercase UUIDs; any other spelling is `invalid_envelope`.
- **Times:** `ts` and every date inside method params and results are milliseconds since 1970. The QR code's `exp` is in seconds.

**Response:**
- Derive `k = ctx.exportSecret(context: "funes-resp-v1", outputByteCount: 32)` from the HPKE context of the request.
- Return `{"v":1,"n":"<12B nonce>","ct":"<AES-GCM-256(k, n, responseJSON)>"}`.
- Only the device that sealed the request (and the Mac) can derive `k`. The response is therefore confidential and authenticated to that exchange.

**Response JSON:** `{"id":"<call id>","result":{…}}` or `{"id":"…","error":{"code":"…","message":"…"}}`.

## 4. Methods
All methods act as the **owner** ([access policy §6](../domain/access-policy.md#6-owner-devices-paired-iphone)). Each is logged in Activity as `device:<id>`.

| Method | Params | Result |
|---|---|---|
| `status.get` | — | `{macName, appVersion, serverTime, inboxPending, vaultActive}` |
| `captures.submit` | `{captures: [{captureId, text, createdAt, source: typed·dictation·share·intent, note?}]}` (≤ 50 per call) | `{accepted: [captureId], rejected: [{captureId, reason}]}`. A duplicate `captureId` counts as **accepted** (idempotent) |
| `categories.list` | — | `[{key, name, description, builtin, defaultSensitivity}]` |
| `memories.search` | `{query, filters?: {categories, kinds, sensitivities, status}, limit ≤ 50, cursor?}` | `{results: [{id, title, snippet, kind, categories, sensitivity, updatedAt, expiresAt}], nextCursor?}` |
| `memories.get` | `{id}` | the full memory plus `provenance` (labels) and `sharedCount`/`lastSharedAt` |
| `memories.create` | `{title, body, kind, categories, sensitivity, expiresAt?}` | `{id, version}` |
| `memories.update` | `{id, version, changes}` | `{version}`, or `conflict` if the version is stale |
| `memories.archive` / `memories.restore` / `memories.delete` | `{id, version}` | `{version}` / `conflict` |
| `inbox.list` | `{cursor?}` | `{items: [suggestion…], nextCursor?}` |
| `inbox.apply` | `{suggestionId, edits?}` | `{memoryId}` |
| `inbox.reject` | `{suggestionId}` | `{}` |
| `device.unpair` | — | `{}`. The Mac marks this device revoked (self-removal) |

**Error codes:**
- `invalid_input`
- `secret_like_content` (with `findings`)
- `not_found`
- `conflict`
- `rate_limited` (with `retry_after_s`)
- `unavailable` (the vault is migrating or locked)
- `unknown_method` (a method this Mac doesn't have, for a newer phone)
- `internal_error`

**Edits:** in `changes` (and `inbox.apply`'s `edits`), an absent field is unchanged; `"expiresAt": null` removes the expiry.

## 5. Transport and reachability
- **Listener:** `NWListener` on TCP 47626, only while iPhone access is on. It accepts or rejects each connection by **remote address**, according to the enabled modes:

| Mode | Accepted source addresses |
|---|---|
| Same Wi-Fi (default) | RFC 1918, link-local, IPv6 ULA/link-local |
| Tailscale | `100.64.0.0/10`, `fd7a:115c:a1e0::/48` |
| Public tunnel | loopback only, because the user's tunnel forwards to `127.0.0.1:47626`. Requests must use the secret path prefix `/r/<128-bit secret>/` and the configured public `Host` (EK Bridge Remote Access pattern) |

- **HTTP:** plain HTTP/1.1 on LAN and Tailscale (the tunnel provides HTTPS for public mode). Confidentiality and integrity come from the envelope (§3).
  - **Metadata still visible on LAN:** device id, timing, sizes.
  - **Hardening option:** TLS with a certificate pinned via the QR code, if Spike 1 shows it's cheap.
- **iOS requirements:**
  - `NSLocalNetworkUsageDescription`, and `NSBonjourServices = ["_funes._tcp"]` (triggers the Local Network permission prompt);
  - ATS `NSAllowsLocalNetworking` for `.local` hosts and IP addresses.
  - Tailscale is reached by its 100.x IP, not a MagicDNS name, to stay within that ATS exception. The tunnel uses HTTPS.
- **Bonjour:** the Mac advertises `_funes._tcp` on port 47626, with TXT `v=1`, `mac=<SHA-256(macId) first 8 bytes hex>`. The phone browses with `NWBrowser` and matches the hash.
- **Address selection (phone):**
  1. A Bonjour hit for the paired Mac.
  2. The saved Tailscale IP.
  3. The saved tunnel URL.

  Each is probed with `status.get` (3 s timeout). The last working address is cached for 10 minutes.

## 6. Offline capture queue (phone)
- **Store:** a SQLite file in the App Group container (shared with the share extension and the App Intent).
  - File protection: `completeUntilFirstUserAuthentication`, so background delivery works after the first unlock.
  - Rows: `{captureId UUID, text, note?, createdAt, source, attempts, lastAttemptAt, state: queued|sent}`.
- **Capture:** the secret scanner runs first; a match blocks the capture with an explanation. The capture is then committed locally, which is the user-visible success. At most 1,000 queued; when full, new captures are refused with "Queue full: connect to your Mac."
- **Delivery triggers:**
  - app launch or foreground;
  - `NWPathMonitor` change to a satisfied path;
  - `BGAppRefreshTask`, opportunistic;
  - right after each new capture while the app is open.

  Extensions never send.
- **Batching:** up to 50 captures per call, oldest first.
- **Exactly once:**
  - The Mac commits each capture together with its `CaptureReceipt` in **one transaction**.
  - A repeated `captureId` returns accepted without creating anything.
  - The phone deletes a capture **only after** receiving `accepted`.
  - A lost response leads to a resend, which is accepted as a duplicate. No loss and no duplicates.
- **Backoff:** exponential from 5 s to 30 min while unreachable. It resets on a path change or the app coming to the foreground.

## 7. Limits (per device)
- 300 calls per minute;
- 50 captures per call, 2,000 per day;
- 256 KiB request body;
- 10 s per call.

## 8. Revocation and unpairing
- **Revoke on the Mac:** the device row gets `revokedAt`. Its next request gets `401 revoked`. The phone shows the revoked state and keeps its queued captures until the user re-pairs or deletes them.
- **Unpair on the phone:** sends `device.unpair` (best effort), then deletes its keys, its pairing record and, after confirmation, its queue.

## 9. Test plan
- Pairing: happy path, expired QR, wrong secret, denied on the Mac, a 4th attempt.
- Envelope: tampered `ct`, `enc` or `sig`; replayed nonce; skewed clock; unknown or revoked device.
- Captures:
  - a duplicate `captureId`;
  - a response dropped after the commit;
  - 1,000 queued, then reconnect;
  - a secret blocked on the phone.
- Reachability: same Wi-Fi, Tailscale, tunnel with the wrong path or Host, Mac asleep and then woken.
- Fuzzing of the envelope parser and the method params.
