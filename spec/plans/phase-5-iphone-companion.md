# Phase 5: iPhone companion (v0.2)

**Goal:** capture anywhere, always. Search, edit and review when the Mac is reachable. No cloud.

**Duration:** 3–4 weekends (+ App Store review). **Depends on:** Spike 1 passed, and v0.1 shipped. Specs: [companion protocol](../architecture/companion-protocol.md), [UX: iPhone](../product/05-ux-iphone.md).

## Tasks
### 5.1 FunesProtocol: companion · 3 h
- [ ] Envelope types, HPKE seal and open, P-256 signatures, the response exporter key, the replay cache.
- [ ] Method request and response types (Codable). Error codes.
- [ ] Tests: crypto round trips, tamper, replay, skew; fuzz the envelope decoder.

### 5.2 Mac: companion server · 4 h
- [ ] `CompanionServer` on 47626 with address-based acceptance per mode; secret path and Host check for tunnel mode.
- [ ] `PairingService`: QR payload, 5-minute sessions, Allow prompt, device storage. `DeviceRegistry`: list, revoke, last seen.
- [ ] Method handlers calling FunesCore as the owner, with Activity rows (`device:<id>`).
- [ ] Bonjour advertiser. iPhone settings section (modes, pairing sheet, devices).

### 5.3 iPhone app: foundation · 3 h
- [ ] Targets: app, share extension, App Intents/Control extension, App Group.
- [ ] Keys: Secure Enclave signing key and Keychain HPKE key.
- [ ] Pairing record in the Keychain. `CompanionClient`: discovery, address selection, retries, `NWPathMonitor`.

### 5.4 Capture and queue · 3 h
- [ ] `CaptureQueue` (App Group SQLite). Capture tab with dictation (SpeechAnalyzer on iOS 26+). Secret scanner on the phone.
- [ ] Delivery triggers and backoff; `BGAppRefreshTask`.
- [ ] Share extension, App Intent "Remember in Funes", Control.

### 5.5 Search, detail, edit, Inbox · 3 h
- [ ] Search tab, memory detail, edit/archive/delete with version conflicts handled ("Changed on your Mac, reload?").
- [ ] Inbox tab with swipe actions.
- [ ] Reachability banner and states; the "Why?" sheet.

### 5.6 Demo mode and App Store · 2 h
- [ ] Demo vault resource and banner. App Review notes.
- [ ] Privacy label "Data Not Collected". Privacy policy at `https://funesvault.com/privacy`, support URL `https://funesvault.com/support`.
- [ ] App Store name "Funes Vault" (reserved early in App Store Connect), subtitle "Private memory for AI agents".
- [ ] TestFlight build; App Store submission.

### 5.7 Testing · 2 h
- [ ] The protocol test plan ([§9](../architecture/companion-protocol.md#9-test-plan)) automated where possible.
- [ ] A manual matrix: same Wi-Fi, Tailscale, tunnel, Mac asleep, revoked device, queue of 1,000.

## Exit criteria
- **v0.2:**
  - a capture made with the Mac asleep arrives exactly once after wake;
  - search and edit work over the same Wi-Fi and over Tailscale;
  - the app is approved on the App Store;
  - the Mac app with iPhone access is released via Sparkle.
