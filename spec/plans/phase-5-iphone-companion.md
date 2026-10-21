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
*The logic is in `Packages/FunesPhone` (`CaptureQueue`, `CaptureDelivery`, `Backoff`, `AppSignal`, `CaptureLaunch`), with Swift Testing tests: persistence across connections and another process, dedupe on retry, backoff, 50-item and byte-budget batches, secret rejection, a lost reply through `CompanionClient`, and a queue of 1,000 draining.*
- [x] `CaptureQueue` (App Group SQLite). Capture tab with dictation (SpeechAnalyzer on iOS 26+). Secret scanner on the phone. *SQLite through the system `SQLite3` library, one connection per call (no lock outlives a call, so a suspended app isn't killed for holding one in the shared container), `BEGIN IMMEDIATE` for the 1,000 cap. Rows leave on `accepted`; a final rejection stays, marked, until the user deletes it; `rate_limited`, `unavailable` and `internal_error` stay queued. Dictation is `DictationTranscriber` on iOS 26+ (the deployment target is 18, so earlier versions point to the keyboard's dictation). The scanner is FunesProtocol's `SecretScanner`, the Mac's own.*
- [x] Delivery triggers and backoff; `BGAppRefreshTask`. *Launch, foreground, a satisfied `NWPathMonitor` path, a new capture (the extensions post a Darwin notification), the backoff's retry while the app is open, and `BGAppRefreshTask` (`com.funesvault.ios.deliver`), scheduled on going to the background and after each run. Backoff 5 s doubling to 30 min, each wait from its upper half; launch, foreground, a path change and Send Now skip it. Batches of at most 50 and 150,000 bytes of JSON, under the Mac's 256 KiB.*
- [x] Share extension, App Intent "Remember in Funes", Control. *All three only add to the queue. The Control's `OpenCaptureIntent` leaves a request in the App Group's defaults (`CaptureLaunch`) and opens the app, which selects Capture and focuses the field. On the device (2026-10-21, [run 2](spike-results.md#run-2-2026-10-21-task-54s-queue-on-the-device-every-capture-arrived-exactly-once)): share sheet, Control and typed captures each arrived once, one made in airplane mode arrived once when the phone came back, and 1,000 drained in about 2 s. Background refresh is still to run.*

### 5.5 Search, detail, edit, Inbox · 3 h
*The view models are in `Packages/FunesPhone` (`SearchModel`, `MemoryDetailModel`, `MemoryEditDraft`, `InboxModel`, `CategoryList`, and `ReachabilityTracker` with `BannerState` and `UnreachableDiagnosis`), calling the Mac through `CompanionCalling`, which `CompanionClient` implements. Swift Testing tests run them against a fake vault that keeps versions (a conflict and Reload, a failed save keeping its draft, a failed or refused Inbox answer putting the row back, one answered on the Mac first, stale search answers dropped, the banner's state machine and the "Why?" hints), and `FunesCompanion`'s `PhoneClientTests` runs the conflict and an Inbox answer through the real client and handlers. No Mac-side change.*
- [x] Search tab, memory detail, edit/archive/delete with version conflicts handled ("Changed on your Mac, reload?"). *Search scopes: Active, Archived, Recently Deleted (`filters.status`), 30 a page. The detail fetches `memories.get` each time it opens and keeps nothing after. Edit sends only the fields that changed, with the version shown; `conflict` asks "Changed on your Mac, reload?", and Reload drops the phone's edit for the Mac's version. Restore is there for archived and deleted memories; there's no Delete Now from the phone.*
- [x] Inbox tab with swipe actions. *Swipe right Save, left Reject (the [glossary](../product/06-glossary.md)'s D3 words; the Mac's Inbox still says Apply), the same in each row's context menu, and Save, Edit & Save… and Reject on the suggestion's screen. The row leaves at once and comes back with the reason if the Mac refuses; `not_found` or `conflict` (answered on the Mac first) just removes it. No Keep Both / Replace choice for corrections: `inbox.apply` has no mode, so the Mac's default applies.*
- [x] Reachability banner and states; the "Why?" sheet. *At the top of Capture, Search and Inbox (Settings keeps its own row). Driven by `status.get` and also by any call that gets no answer, capture delivery's outcome, and `NWPathMonitor` (offline turns a connected banner to "Mac not reachable" at once). The "Why?" sheet gives the spec's explanation, hints from the network path, the pairing's addresses and the last probes (offline, Local Network off, a refused connection meaning Funes Vault isn't listening, off Wi-Fi with or without Tailscale, the Mac asleep), and Try Again. On the device (2026-10-21, [run 3](spike-results.md#run-3-2026-10-21-task-55s-search-edit-and-inbox-on-the-device-all-four-checks-pass-after-three-fixes)): search, a conflicting edit with Reload, an Inbox swipe and the banner with the Mac app quit all pass, after three fixes found there.*

### 5.6 Approvals from the iPhone · 5 h
*[FR-iOS-12](../product/03-requirements.md); the push channel is [Q24](open-questions.md): decided, a CloudKit doorbell ([ADR-0019](../architecture/decisions/0019-cloudkit-doorbell-for-iphone-approvals.md)).*
- [x] Early in the phase: measure the chosen channel's delivery time from the Mac to a locked phone (a CloudKit doorbell first). *Passed 2026-10-20: 31 of 31 rings, median 1.1 s, max 1.7 s ([results](spike-results.md#q24-cloudkit-doorbell-delivery-time)); CloudKit chosen, [ADR-0019](../architecture/decisions/0019-cloudkit-doorbell-for-iphone-approvals.md).*
- [x] Mac: when a Share, Save or access request starts waiting, ring the doorbell for each paired device with approvals on. It carries only "you have a request" and an opaque id: no text, titles, task or agent name. *`CompanionApprovals` (FunesCompanion) rings through a `DoorbellChannel`; the app's `CloudKitDoorbell` saves one `Doorbell` record per device with only `tag`, under a fresh random 128-bit name it maps to the request in memory ([companion protocol §4.1](../architecture/companion-protocol.md#41-approvals-from-the-iphone-task-56)). Only while iPhone access is on, to devices that have fetched their tag; deleted when the request stops waiting and at launch. CloudKit runs only in a build signed with the container: the Mac app's iCloud entitlement (`Apps/FunesMac.entitlements`) waits for `com.funesvault.mac` to get iCloud in the portal and a Developer ID profile, so until then the Mac reports `unsupported` and nothing rings.*
- [x] Companion methods to fetch a waiting request's panel contents and to answer it. The answer is bound to the request id and its snapshot revision, single use, with the same 15-minute and invalidation rules ([access policy](../domain/access-policy.md)); the first answer wins on the Mac or the phone. *`approvals.list`, `approvals.get` (by id, or by the ring's record name for the extension), `approvals.answer`, and the errors `already_answered`, `request_expired`, `request_changed`. A Share answer re-checks the snapshot first (T22); a phone's Deny never takes back an approval given first (`deny(waitingOnly:)`, also the Mac panel's Deny). A phone's win closes the Mac's panel with "Answered on <iPhone>."*
- [ ] iPhone: a notification (worded on the phone by a notification service extension, after fetching over the companion channel), and the Share and Save panels with checkboxes and badges. Answering needs the phone unlocked. "Mac not reachable" when it can't fetch.
- [ ] Settings ▸ iPhone on the Mac and Settings on the phone: approvals on or off per device (default on once paired). *Mac done: an "Approve requests on this iPhone" switch per device, stored with the device (`approvals_enabled`, migration `v3_device_approvals`), and a line saying whether this Mac can notify (iCloud signed in, a build with the entitlement). The phone's side is `approvals.settings.get`/`.set`; its switch comes with the panels.*
- [x] Tests: the push payload never contains text (captured); a phone answer and a Mac answer racing; a revoked device's answer refused; Activity rows under the device. *`ApprovalsTests` in FunesCompanion, against the real router and vault, with a recording doorbell: also a stale revision, an expired request, Save and access panels, records deleted when a request stops waiting. FunesCore's `DeviceApprovalsTests` cover the switch, the tag and the v3 migration.*

### 5.7 Demo mode and App Store · 2 h
- [ ] Demo vault resource and banner. App Review notes.
- [ ] Privacy label "Data Not Collected". Privacy policy at `https://funesvault.com/privacy`, support URL `https://funesvault.com/support`.
- [ ] App Store name "Funes Vault" (reserved early in App Store Connect), subtitle "Private memory for AI agents".
- [ ] TestFlight build; App Store submission.

### 5.8 Testing · 2 h
- [ ] The protocol test plan ([§9](../architecture/companion-protocol.md#9-test-plan)) automated where possible.
- [ ] A manual matrix: same Wi-Fi, Tailscale, tunnel, Mac asleep, revoked device, queue of 1,000, background delivery (a share-sheet capture with the app in the background, then `BGAppRefreshTask` forced from the Xcode debugger; spike row 1h); approvals from the phone on Wi-Fi and Tailscale, locked phone, Mac unreachable.

## Exit criteria
- **v0.2:**
  - a capture made with the Mac asleep arrives exactly once after wake;
  - search and edit work over the same Wi-Fi and over Tailscale;
  - a request from ChatGPT or claude.ai is approved from the phone, with no memory text in the push;
  - the app is approved on the App Store;
  - the Mac app with iPhone access is released via Sparkle.
