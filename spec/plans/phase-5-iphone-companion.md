# Phase 5: iPhone companion (v0.2)

**Goal:** capture anywhere, always. Search, edit and review when the Mac is reachable. **Approve agents' requests from the phone,** the main reason for the companion ([Q16](open-questions.md)). No cloud copy.

**Duration:** 4–5 weekends (+ App Store review), one more than before for approvals from the iPhone. **Depends on:** Spike 1 passed, and v0.1 shipped. Specs: [companion protocol](../architecture/companion-protocol.md), [UX: iPhone](../product/05-ux-iphone.md).

## Tasks
### 5.1 FunesProtocol: companion · 3 h
- [x] Envelope types, HPKE seal and open, P-256 signatures, the response exporter key, the replay cache.
- [x] Method request and response types (Codable). Error codes.
- [x] Tests: crypto round trips, tamper, replay, skew; fuzz the envelope decoder.

### 5.2 Mac: companion server · 4 h
*In `Packages/FunesCompanion`; Settings ▸ iPhone is hidden in Release builds until the iPhone app ships.*
- [x] `CompanionServer` on 47626 with address-based acceptance per mode; secret path and Host check for tunnel mode.
- [x] `PairingService`: QR payload, 5-minute sessions, Allow prompt, device storage. Device registry (FunesCore `DeviceService`): list, revoke, last seen.
- [x] Method handlers calling FunesCore as the owner, with Activity rows (`device:<id>`).
- [x] Bonjour advertiser. iPhone settings section (modes, pairing sheet, devices).
- [x] Accept connections over Tailscale. *Spike 1e (2026-10-21): `NWListener` never completes the handshake for flows arriving on Tailscale's `utun` interface, while a POSIX socket listener does ([results](spike-results.md#spike-1-companion-transport)). `CompanionListener` now accepts on a BSD socket; `ListenerTests` reaches it through the Mac's own 100.x address. With 5.3's ATS fix, 1e passes on the iPhone: Connected · Tailscale on 5G.*

### 5.3 iPhone app: foundation · 3 h
*The app's code that isn't UI is the local package `Packages/FunesPhone` (iOS and macOS, so `swift test` runs it); `FunesCompanion`'s tests run its `CompanionClient` against the real router.*
- [x] Targets: app, share extension, App Intents/Control extension, App Group. *`FunesiOS`, `FunesShareExtension` and `FunesIntents` (a WidgetKit extension holding the Control), folder-synchronized; App Group and Keychain Sharing on all three; built in `scripts/test.sh` for `generic/platform=iOS` without signing. The extensions are shells until 5.4.*
- [x] Keys: Secure Enclave signing key and Keychain HPKE key. *`…AfterFirstUnlockThisDeviceOnly`, in the shared access group; a Keychain software key where the Secure Enclave fails. New keys at each pairing, saved only once it succeeds.*
- [x] Pairing record in the Keychain. `CompanionClient`: discovery, address selection, retries, `NWPathMonitor`. *Minimal UI: pair by QR (VisionKit), the connection and `status.get`, and in Debug builds Spike 1's test capture and protocol checks.*

### 5.4 Capture and queue · 3 h
- [ ] `CaptureQueue` (App Group SQLite). Capture tab with dictation (SpeechAnalyzer on iOS 26+). Secret scanner on the phone.
- [ ] Delivery triggers and backoff; `BGAppRefreshTask`.
- [ ] Share extension, App Intent "Remember in Funes", Control.

### 5.5 Search, detail, edit, Inbox · 3 h
- [ ] Search tab, memory detail, edit/archive/delete with version conflicts handled ("Changed on your Mac, reload?").
- [ ] Inbox tab with swipe actions.
- [ ] Reachability banner and states; the "Why?" sheet.

### 5.6 Approvals from the iPhone · 5 h
*[FR-iOS-12](../product/03-requirements.md); the push channel is [Q24](open-questions.md): decided, a CloudKit doorbell ([ADR-0019](../architecture/decisions/0019-cloudkit-doorbell-for-iphone-approvals.md)).*
- [x] Early in the phase: measure the chosen channel's delivery time from the Mac to a locked phone (a CloudKit doorbell first). *Passed 2026-10-20: 31 of 31 rings, median 1.1 s, max 1.7 s ([results](spike-results.md#q24-cloudkit-doorbell-delivery-time)); CloudKit chosen, [ADR-0019](../architecture/decisions/0019-cloudkit-doorbell-for-iphone-approvals.md).*
- [ ] Mac: when a Share, Save or access request starts waiting, ring the doorbell for each paired device with approvals on. It carries only "you have a request" and an opaque id: no text, titles, task or agent name.
- [ ] Companion methods to fetch a waiting request's panel contents and to answer it. The answer is bound to the request id and its snapshot revision, single use, with the same 15-minute and invalidation rules ([access policy](../domain/access-policy.md)); the first answer wins on the Mac or the phone.
- [ ] iPhone: a notification (worded on the phone by a notification service extension, after fetching over the companion channel), and the Share and Save panels with checkboxes and badges. Answering needs the phone unlocked. "Mac not reachable" when it can't fetch.
- [ ] Settings ▸ iPhone on the Mac and Settings on the phone: approvals on or off per device (default on once paired).
- [ ] Tests: the push payload never contains text (captured); a phone answer and a Mac answer racing; a revoked device's answer refused; Activity rows under the device.

### 5.7 Demo mode and App Store · 2 h
- [ ] Demo vault resource and banner. App Review notes.
- [ ] Privacy label "Data Not Collected". Privacy policy at `https://funesvault.com/privacy`, support URL `https://funesvault.com/support`.
- [ ] App Store name "Funes Vault" (reserved early in App Store Connect), subtitle "Private memory for AI agents".
- [ ] TestFlight build; App Store submission.

### 5.8 Testing · 2 h
- [ ] The protocol test plan ([§9](../architecture/companion-protocol.md#9-test-plan)) automated where possible.
- [ ] A manual matrix: same Wi-Fi, Tailscale, tunnel, Mac asleep, revoked device, queue of 1,000; approvals from the phone on Wi-Fi and Tailscale, locked phone, Mac unreachable.

## Exit criteria
- **v0.2:**
  - a capture made with the Mac asleep arrives exactly once after wake;
  - search and edit work over the same Wi-Fi and over Tailscale;
  - a request from ChatGPT or claude.ai is approved from the phone, with no memory text in the push;
  - the app is approved on the App Store;
  - the Mac app with iPhone access is released via Sparkle.
