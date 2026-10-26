# Companion protocol (Mac ↔ iPhone)

**Status:** design for v0.2, to be validated in [Spike 1](../plans/phase-0-spikes.md). §2–4 are implemented in `FunesProtocol/Companion` (task 5.1), with the byte-level choices in §3.1; the Mac's side in `FunesCompanion` (task 5.2) and the phone's in `FunesPhone` (task 5.3, §5). §4.1, approvals from the iPhone, is implemented on the Mac (task 5.6); the phone's panels and notification service extension come next. Spike 1 ran on a real iPhone on 2026-10-21: pairing, the envelope and Bonjour pass, and the Tailscale mode fails on the Mac's listener (§5, [results](../plans/spike-results.md#spike-1-companion-transport)).

The iPhone is a **thin client** of the Mac. There is no replication and no cloud ([ADR-0003](decisions/0003-mac-is-the-only-source-of-truth.md)). Messages are **signed by the device and end-to-end encrypted at the application layer** ([ADR-0011](decisions/0011-app-layer-encryption-for-companion.md)). Neither the LAN, Tailscale nor a tunnel provider can read or forge them.

## 1. Keys
| Key | Algorithm | Where | Purpose |
|---|---|---|---|
| Mac signing key | P-256 ECDSA | Mac Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` | Signs pairing confirmations |
| Mac HPKE key | P-256 key agreement | Mac Keychain, same | Recipient of every phone request |
| Device signing key | P-256 ECDSA | iPhone **Secure Enclave** (`SecureEnclave.P256.Signing`); Keychain fallback on devices without one | Signs every request |
| Device HPKE key | P-256 key agreement | iPhone Keychain (`…AfterFirstUnlockThisDeviceOnly`) | Recipient of pairing confirmations |
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

   It then shows **"<deviceName> wants to pair · Allow / Deny"** on the Mac. This is a second factor, so a leaked photo of the QR code isn't enough. The HTTP request waits for the answer, up to 60 s (then it's a Deny), so the phone waits at least 65 s for this call. While the Mac asks, other attempts on the same session are refused.
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
- **Both endpoints** take `Content-Type: application/funes-envelope+json` and `POST` only. Otherwise the reply is `415` or `405`, and an unknown path is `404`.
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
All methods act as the **owner** ([access policy §6](../domain/access-policy.md#6-owner-devices-paired-iphone)). Each is logged in Activity as `device:<id>` (via `companion`), except `status.get`, the reachability probe the phone sends on every foreground, and `approvals.settings.get`, which it sends as often. Reads log one row without text (`memories_searched` with a result count, `memory_viewed`, `inbox_listed`, `categories_listed`, `approvals_listed`, `approval_viewed`, and from v0.4 `overview_viewed`). Writes log what FunesCore logs for them (`capture`, `memory_created`, `memory_edited`, `memory_archived`, `memory_restored`, `memory_deleted`, `suggestion_applied`, `suggestion_rejected`, `device_revoked`, `approval`, `access_answered`, `device_approvals`).

**Implementation (task 5.2):** the Mac's side is the local package `Packages/FunesCompanion`: `CompanionListener`, `CompanionRouter`, `PairingService`, `CompanionHandlers` and `CompanionServer`, on FunesCore and BridgeKitCore's HTTP parser. The app adds only Settings ▸ iPhone and the Allow prompt. The Mac's id and keys are a Keychain item, service `com.funesvault.companion` (`.dev` for a development vault).

| Method | Params | Result |
|---|---|---|
| `status.get` | — | `{macName, appVersion, serverTime, inboxPending, vaultActive, calledName?}`. `calledName` (v0.5) is the name the profile says to call the user (preferred, else given), for Home's title; the phone keeps the last one in its pairing record ([ADR-0026](decisions/0026-about-you-profile.md)) |
| `captures.submit` | `{captures: [{captureId, text, createdAt, source: typed·dictation·share·intent, note?}]}` (≤ 50 per call) | `{accepted: [captureId], rejected: [{captureId, reason}]}`. A duplicate `captureId` counts as **accepted** (idempotent) |
| `overview.get` (v0.4) | `{range: 30d·12w·12m}` | the vault's counts for the range, never memory text or titles ([ADR-0025](decisions/0025-vault-overview-and-iphone-cache.md)): `{range, generatedAt, timeZone, total, thisWeek: {saved, shared, agents, refused}, days: [{date, in: {mac, iphone, agent, import, tidy}, out: {<agentId>: n}, refused}], rhythm: {start, counts}, bySensitivity, byCategory, byKind, sharedBySensitivity, sharedByCategory, refusedByReason, withheld, agents: [{id, name, kind, shared, requests, lastRequestAt?}], inboxPending, oldestPendingAt?, lastTidyUpAt?}`. `days` has 30 days, or 12 weeks or 12 months for 12w and 12m, oldest first, each starting at midnight in `timeZone` (the Mac's); the last holds now. `in` counts new memories by source (`iphone` includes memories typed on a paired iPhone; `mac` includes the setup's questions), `out` memories delivered (a request that shares 3 counts 3). `thisWeek` is the last 7 days, today included; `rhythm` 84 daily counts of new memories ending today, whatever the range. The `by…` maps are active memories, keyed by sensitivity name, category key and kind; `shared…` what the range delivered; `refusedByReason` the refused requests by reason code, and `withheld` what they withheld. `agents` lists agents not removed, and removed ones with a request in the range, most shared first. The phone caches the last answer for each range (§6.1) |
| `categories.list` | — | `[{key, name, description, builtin, defaultSensitivity}]` |
| `memories.search` | `{query, filters?: {categories, kinds, sensitivities, status}, limit ≤ 50, cursor?}` | `{results: [{id, title, snippet, kind, categories, sensitivity, updatedAt, expiresAt}], nextCursor?}` |
| `memories.get` | `{id}` | the full memory plus `provenance` (labels) and `sharedCount`/`lastSharedAt` |
| `memories.create` | `{title, body, kind, categories, sensitivity, expiresAt?}` | `{id, version}` |
| `memories.update` | `{id, version, changes}` | `{version}`, or `conflict` if the version is stale |
| `memories.archive` / `memories.restore` / `memories.delete` | `{id, version}` | `{version}` / `conflict` |
| `inbox.list` | `{cursor?}` | `{items: [suggestion…], nextCursor?}` |
| `inbox.apply` | `{suggestionId, edits?}` | `{memoryId}`, or `target_changed` / `unsupported_action` / `processing` (Phase 6) |
| `inbox.reject` | `{suggestionId}` | `{}`. A suggestion still processing may be rejected; its processing is cancelled |
| `inbox.retry` | `{suggestionId}` | `{}`: Try again on a failed split (its job is queued again), or `conflict` if it isn't failed |
| `inbox.keep` | `{suggestionId}` | `{}`: Keep as one on a failed split (an ordinary suggestion from then on), or `conflict` if it isn't failed |
| `device.unpair` | — | `{}`. The Mac marks this device revoked (self-removal) |
| `approvals.list` | — | `{items: [{id, kind, agentName, agentKind?, count, createdAt, expiresAt}]}`: what waits now, soonest deadline first (§4.1) |
| `approvals.get` | `{id}` or `{ring}` (exactly one) | the panel: `{id, kind, revision, agentName, agentKind?, task?, createdAt, expiresAt, share? \| save? \| access?}` (§4.1) |
| `approvals.answer` | `{id, revision, choice, memoryIds?}` | `{choice, memoryId?}`, or `already_answered`, `request_expired`, `request_changed` (§4.1) |
| `approvals.settings.get` | — | `{enabled, tag?, container, recordType, doorbell}` (§4.1) |
| `approvals.settings.set` | `{enabled}` | the same |

**Error codes:**
- `invalid_input`
- `secret_like_content` (with `findings`)
- `not_found`
- `conflict`
- `rate_limited` (with `retry_after_s`)
- `unavailable` (the vault is migrating or locked)
- `unknown_method` (a method this Mac doesn't have, for a newer phone)
- `internal_error`
- `already_answered` (`approvals.*`: answered first, on the Mac or another iPhone)
- `request_expired` (`approvals.*`: past its 15 minutes, an access request's in-call wait over, or withdrawn or invalidated)
- `request_changed` (`approvals.answer`: a stale `revision`; fetch the panel again)
- `target_changed` (`inbox.apply`: a memory the suggestion changes was edited, archived or deleted since it was suggested; the suggestion is still waiting, to be reviewed again on the Mac)
- `unsupported_action` (`inbox.apply`: merge, split, conflict and unknown actions, and the daily tidy-up's proposals, are answered on the Mac)
- `processing` (`inbox.apply`, `approvals.answer`: New memories processing hasn't finished with the suggestion; list the Inbox again later)

**Edits:** in `changes` (and `inbox.apply`'s `edits`), an absent field is unchanged; `"expiresAt": null` removes the expiry.

**Phase 6 (v0.3) Inbox changes** ([ADR-0020](decisions/0020-atomic-extraction-for-every-source.md), [ADR-0021](decisions/0021-daily-tidy-up.md)):
- `inbox.list` items gain `groupId?`, `groupLabel?` ("ChatGPT · 12 pieces"), `outsideScope` and `targetMemoryVersion?`. `action` gains `duplicate`, `split`, `merge` and `conflict`.
- `inbox.list` items gain `processing?`: `processing` while New memories processing holds the suggestion (memory processing §5.2: its job is queued or running with splitting on), `failed` when its split failed; absent otherwise. A `processing` item is shown greyed and can't be saved (`inbox.apply` answers `processing`), only rejected, which cancels its job. A `failed` one offers Try again (`inbox.retry`) and Keep as one (`inbox.keep`). Both apps are updated together.
- The phone decodes an action it doesn't know as `unknown` and shows such items as "Review on your Mac". Both apps are updated together (there are no external users yet), so the Mac doesn't filter by phone version.
- `inbox.apply` applies the suggestion's own action (the same per-action apply as the Mac): `create` saves, `update` replaces its target, `archive` archives it, `duplicate` changes nothing. A stale target returns `target_changed` (not `conflict`, which the phone's Inbox reads as "answered on your Mac"). Merge, split and conflict suggestions are answered on the Mac until the phone gets their cards; `inbox.apply` refuses them from the phone with `unsupported_action`. So are the daily tidy-up's proposals (origin `consolidation`, whatever their action, ADR-0021): `inbox.list` sends them with action `unknown`, so the phone shows "Review on your Mac", because a tidy-up update may also archive a copy and an archive names the memory it keeps, which the phone's cards don't show. The phone may still reject them.

### 4.1 Approvals from the iPhone (task 5.6)
[FR-iOS-12](../product/03-requirements.md), [ADR-0019](decisions/0019-cloudkit-doorbell-for-iphone-approvals.md). The Mac's side is `CompanionApprovals` in `FunesCompanion`; the types are `FunesProtocol/Companion/CompanionApprovals.swift`.

**The doorbell.** When a Share, Save or access panel starts waiting on the Mac (not a pending request reopened there), the Mac saves one `Doorbell` record per paired, unrevoked device that has approvals on and has fetched its tag, in the user's private database of `iCloud.com.funesvault` (default zone):
- the record name is 32 lowercase hex digits, a fresh random 128-bit value per ring and device; the Mac maps it to the request in memory only;
- the only field is `tag`, the device's random tag (`approvals.settings.get`);
- nothing else: no text, titles, task, agent name, counts or request id. The adapter takes only `{recordName, tag}`, and a test checks what it's given.

The Mac rings only while iPhone access is on, at most once per request and device. It deletes the records when the request is answered (on the Mac or a phone), expires or is invalidated, when iPhone access or the device's approvals are turned off or the device is removed, and at launch (a query on the tags). The phone subscribes with a `CKQuerySubscription` on `tag == <its tag>`, firing on creation, with a fixed alert, `shouldSendMutableContent` and no desired keys (ADR-0019 §2). Its notification service extension reads the record name from the push and calls `approvals.get {ring}`.

**What waits** (`approvals.list`, `approvals.get`):
- **Share:** a request in `needs_approval` for less than 15 minutes (access policy §3.6, §3.9), listed even after a relaunch of the Mac. `id` is the request id.
- **Save:** an agent's suggestion whose Save panel the Mac showed, while it's pending and for 15 minutes from then. `id` is the suggestion id. After that it's still in the Inbox (`inbox.apply`). With splitting on, the Mac shows the panel only once New memories processing is done (memory processing §5.6), so there's no Save approval for a suggestion still processing; a split one rings once per piece, each with the piece's id.
- **Access:** "<Agent> wants to read <Category>", while the agent's in-call wait lasts. `id` is the Mac's own, in memory only.

`approvals.get` builds the panel fresh, as the Mac's does. A Share request's snapshot is re-checked against the current memories and access first, so its `revision` is the current `snapshotRevision`. It has one of:
- `share`: `{destination: {remote, vendor?, tunnel?}, keywords, purpose?, retention, processors, declaredRetention?, rows: [{id, title, body, version, kind, categories, sensitivity, weak}], withheld: {<reason code>: count}}`. The rows carry the current text in full, in score order; `weak` rows are offered unticked. Withheld memories are counts by reason, never ids (ADR-0012);
- `save`: `{action, targetMemoryId?, title, body, kind?, categories, sensitivity?, expiresAt?, evidence?, purpose?}`. Its `revision` is a SHA-256 of what would be saved;
- `access`: `{operation, categoryKey?, categoryName?, allowsOnce, asksBeforeSharing}`. Its `revision` is random per panel.

The Mac words nothing for the phone: the panels are data, worded and localized on the phone ("Claude Code wants 3 memories"). Agent-provided fields (`task`, `keywords`, `purpose`, `evidence`) are shown as reported, never checked.

**Answers** (`approvals.answer`): `choice` is `share` (with `memoryIds`, at least one, all from the panel) or `deny`; `save` or `discard` (Later is no call); `allow_once` (only when `allowsOnce`), `always_allow` or `not_now`. A choice for another kind of panel is `invalid_input`.
- Bound to `id` and `revision`, single use. A Share answer re-checks the snapshot first, so a panel shown before a memory or the agent's access changed is `request_changed` (T22); the phone fetches it again.
- The first answer wins, on the Mac or a phone. Share and Save are decided in FunesCore's transactions (a phone's Deny never takes back an approval given first), an access request by the Mac's panel queue. The loser gets `already_answered`, and so does every later call for it.
- Past 15 minutes (or the in-call wait for access) it's `request_expired`, and so is a request invalidated in the meantime.
- A revoked device's call is refused before any of this (`401 revoked`), and the Mac checks again before answering.
- When a phone wins, the Mac's panel closes with "Answered on Sam's iPhone.", and an agent waiting in its call gets its answer at once.
- Not resent automatically (§5): a lost reply is checked with `approvals.get`, which then says `already_answered`.

**Settings** (`approvals.settings.*`): approvals per device, on by default once paired, set on the Mac (Settings ▸ iPhone) or the phone. `get` returns the device's tag while they're on, creating it the first time; turning them off drops the tag, and the next one is new, so an old subscription goes quiet. `doorbell` says whether this Mac can ring at all: `available`, `no_account` (not signed in to iCloud), `restricted`, or `unsupported` (a build without the iCloud entitlement). Without it, approvals still work on the Mac and in the phone app's list.

**The phone's side** (`FunesPhone`, the app and its notification service extension `com.funesvault.ios.notifications`):
- **Subscribing.** On every foreground while connected, the app calls `approvals.settings.get`, then makes its subscriptions match (`DoorbellSubscriptionPlan`): one `doorbell-<tag>` while approvals are on and the Mac has given a tag, none otherwise, so a stale tag's subscription goes. Nothing is subscribed before the Mac's answer. The fixed alert is "You have a request", localized on the phone. The switch in Settings is `approvals.settings.set`, and unpairing deletes the subscription. Notification permission is asked the first time the phone subscribes.
- **The extension** reads the record name (`CKQueryNotification`), stores it in the notification's `userInfo` (`funesRing`), and calls `approvals.get {ring}` through `CompanionClient` with the shared Keychain pairing and keys, giving it 10 s. It words the alert on the phone (`ApprovalAlert`): from the panel, or "Answered on your Mac" (`already_answered`), "This request expired" (`request_expired`), the generic text (`not_found`, a removed device) or "Mac not reachable" (no answer). It puts the request's `id` and `kind` in `userInfo` for the tap, and never answers.
- **Answering** happens in the app, with the phone unlocked (protected data available). `request_changed` fetches the panel again for the user to review; `already_answered` closes it ("Answered on your Mac"); an answer with no reply isn't resent, and the next `approvals.get` then says `already_answered`.

**Activity**, under `device:<id>` via `companion`: `approvals_listed` (with the count), `approval_viewed` (with the request id for Share), the answer as FunesCore logs it (`approval` approved or denied, the suggestion applied or rejected), `access_answered` (with the choice), and `device_approvals` (on or off). `approvals.settings.get` isn't logged.

## 5. Transport and reachability
- **Listener:** a BSD socket on TCP 47626 (the `CompanionPort` preference), only while iPhone access is on, which is off by default. It's one dual-stack socket on `::`, so it covers every interface, including Tailscale coming up later. With only tunnel mode on, it binds `127.0.0.1` and `::1` instead, so nothing outside the Mac reaches the port. It accepts or rejects each connection by **remote address**, according to the enabled modes, before reading a byte:

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
  - ATS refuses plain HTTP to Tailscale's `100.64.0.0/10` addresses even with that exception (`URLError -1022`, [Spike 1e](../plans/spike-results.md#spike-1-companion-transport)). So the phone sends plain HTTP, LAN and Tailscale, over Network.framework, which ATS doesn't govern. Tailscale is reached by its 100.x IP, not a MagicDNS name. The tunnel uses HTTPS through `URLSession`.
- **Subnet routers:** a Tailscale subnet router (or any VPN gateway) that routes the Mac's LAN presents the phone's traffic as coming from a LAN address. Same Wi-Fi mode then accepts it from anywhere on that VPN, and the phone, which tries LAN addresses first, uses it ([Spike 1e](../plans/spike-results.md#spike-1-companion-transport)). The envelope still makes every request authenticated and confidential. The phone shows "Connected · VPN" when a LAN address answers while it isn't on Wi-Fi or Ethernet.
- **Why not `NWListener` (Spike 1e, 2026-10-21):** on macOS 27, an `NWListener` gets inbound flows over Tailscale's `utun` interface but never completes the TCP handshake, so the phone couldn't reach the Mac's 100.x address. The kernel's `accept` on a BSD socket does. `CompanionListener` accepts with a dispatch source and advertises Bonjour through `DNSServiceRegister`.
- **Bonjour:** while Same Wi-Fi is on, the Mac advertises `_funes._tcp` on port 47626, with TXT `v=1`, `mac=<SHA-256(macId) first 8 bytes hex>` (the hash of the lowercase id string). The phone browses with `NWBrowser` and matches the hash. The Mac app's Info.plist has `NSLocalNetworkUsageDescription` and `NSBonjourServices` for macOS's Local Network permission.
- **HTTP refusals before the envelope:** tunnel requests without the secret prefix `404`, with the wrong `Host` `421`; a `/r/…` path off the tunnel `404`; a body over 256 KiB `413`. The whole request must arrive within 10 s of its first byte (`408`), and an idle connection closes after 30 s.
- **The QR code's addresses:** the Mac's `.local` name and its current LAN IPv4 address (Same Wi-Fi), its `100.x` address (Tailscale), and `https://<public host>/r/<secret>` (tunnel). Only enabled modes are listed. **Reset Path** in Settings makes a new secret; phones learn it by pairing again.
- **Address selection (phone):**
  1. A Bonjour hit for the paired Mac, or a LAN address saved from the QR code (same Wi-Fi, so whichever answers first).
  2. The saved Tailscale IP.
  3. The saved tunnel URL.

  Each is probed with `status.get` (3 s timeout), all at once, with the Bonjour browse (2 s) alongside. The best-ranked address that answers wins as soon as no better-ranked probe is still running. The last working address is cached for 10 minutes, and forgotten when `NWPathMonitor` reports a new path. If none answers, a `401 revoked` from any of them is reported as revoked; otherwise the Mac is unreachable, with "Local Network access is off" when iOS refused the browse.
- **Before pairing,** the phone has no device id to seal a `status.get` with, so it probes the QR code's addresses (and Bonjour) with an empty `POST /c/v1/rpc`: a Funes Mac answers `401 invalid_envelope` without reading further. Only then does it send the pairing request, so an address that doesn't answer never uses up one of the session's 3 attempts. The request goes to the best-ranked address that answered.
- **Retries (phone):** a `clock_skew` refusal is resent once, sealed with the Mac's `server_time`, and the offset is kept for later calls. A call with no answer at all (no connection, a timeout, a lost response) starts address selection over and is resent once if it's safe to repeat: `status.get`, `captures.submit` (duplicates are accepted, §6) and the reads (with `overview.get`, `approvals.list`, `approvals.get` and `approvals.settings.get`). Edits, deletes, Inbox answers, approval answers, `approvals.settings.set` and `device.unpair` aren't resent; the user sees the error and can try again, and a stale `version` comes back as `conflict`.
- **Implementation (task 5.3):** `Packages/FunesPhone`: `CompanionClient` (an actor), `DeviceKeyStore`, `PairingRecordStore`, `BonjourDiscovery` (an `NWBrowser`; a match is resolved to its IPv4 address by opening a TCP connection, since `URLSession` can't use a service endpoint), `NetworkPathWatcher`, and `CompanionHTTPTransport`: a small HTTP/1.1 client on `NWConnection` for `http://` (one POST per connection, `Connection: close`, the reply read to its `Content-Length`, at most 4 MiB), and an ephemeral `URLSession` for the tunnel's `https://`. Each request has a hard deadline. The device keys and the pairing record are Keychain items, service `com.funesvault.ios.companion`, in the access group the app and its extensions share. The phone waits 70 s for the pairing answer.

## 6. Offline capture queue (phone)
- **Store:** a SQLite file in the App Group container (shared with the share extension and the App Intent).
  - File protection: `completeUntilFirstUserAuthentication`, so background delivery works after the first unlock.
  - Rows: `{captureId UUID, text, note?, createdAt, source, attempts, lastAttemptAt, state: queued|rejected, rejectReason?}`. A capture's row is deleted when the Mac accepts it; "Sent to Mac ✓" in Recent captures is kept in memory for the session only. A `rejected` row is one the Mac won't ever take (`invalid_input`, `secret_like_content`): it stays, marked, until the user deletes it. `rate_limited`, `unavailable` and `internal_error` leave it `queued`.
  - Each operation opens its own connection and closes it (default rollback journal, `BEGIN IMMEDIATE` for the capacity check), so the app and the extensions share the file and no lock is held while the app is suspended.
- **Capture:** the secret scanner runs first; a match blocks the capture with an explanation. The capture is then committed locally, which is the user-visible success. At most 1,000 queued; when full, new captures are refused with "Queue full: connect to your Mac."
- **Delivery triggers:**
  - app launch or foreground;
  - `NWPathMonitor` change to a satisfied path;
  - `BGAppRefreshTask`, opportunistic;
  - right after each new capture while the app is open (the share extension and the App Intents post a Darwin notification the open app listens for);
  - while the app is open, when the backoff's wait is over.

  Extensions never send. The app schedules the background refresh each time it goes to the background and after each refresh. From v0.4 (task 7.5) the background refresh also asks for the 30-day overview after delivering, so the widgets stay current while the app is closed; a failure keeps the cache.
- **Implementation (task 5.4):** `Packages/FunesPhone`: `CaptureQueue` (the store and its checks: trimmed, at most 10,000 characters with the note, the secret scanner), `CaptureDelivery` (an actor: triggers, batches, the backoff) and `AppSignal`.
- **Batching:** up to 50 captures per call, oldest first, and at most 150,000 bytes of capture JSON, so the sealed request stays under the Mac's 256 KiB (one capture always goes, however long).
- **Exactly once:**
  - The Mac commits each capture together with its `CaptureReceipt` in **one transaction**.
  - A repeated `captureId` returns accepted without creating anything.
  - The phone deletes a capture **only after** receiving `accepted`.
  - A lost response leads to a resend, which is accepted as a duplicate. No loss and no duplicates.
- **Backoff:** exponential from 5 s to 30 min while unreachable (or while every capture in a call comes back `rate_limited`), each wait drawn from the upper half of its step. It resets on a path change, the app coming to the foreground, **Send now**, and any call that delivers. A new capture and a background refresh wait it out.

### 6.1 Overview cache (phone, v0.4)
The last `overview.get` answer for each range is kept in `overview.json` in the App Group container (`OverviewCache` in FunesPhone; `{overviews: {"30d": {…}, "12w": {…}}}`), so Home's 30 days and the widgets don't lose theirs when the longer ranges are opened: written atomically after each successful call, file protection `completeUntilFirstUserAuthentication`, read by Home and the widgets, and deleted on unpair, on revocation and when leaving the demo ([ADR-0025](decisions/0025-vault-overview-and-iphone-cache.md)). It holds counts, dates and agent names only. The app asks for 30 days on launch, foreground and refresh (task 7.2), the longer ranges when Home's sheet opens them (7.4). Entering or leaving the demo also deletes it, so it's never a mix of the demo's counts and the Mac's.

## 7. Limits (per device)
- 300 calls per minute (then `rate_limited` with `retry_after_s`, inside the encrypted reply);
- 50 captures per call, 2,000 per day (captures over the day's limit come back as `rejected` with `rate_limited`);
- 256 KiB request body;
- 10 s per call (then `unavailable`; the work still finishes on the Mac, and a capture's receipt keeps a resend from duplicating it).

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
- Approvals (§4.1): the doorbell records carry only a tag and a random name (captured); a phone answer and a Mac answer racing; a stale revision; an expired request; a revoked device's answer; Activity rows under the device; records deleted when the request stops waiting.
- Fuzzing of the envelope parser and the method params.
