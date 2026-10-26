# Phase 7: Home, widgets and the iPhone's status bar

**Goal:** bring back the web version's Home on both apps, extended with what only Funes knows: a place to add a memory right there, and the vault's pulse (what came in, what went out to your agents, its shape and rhythm), plus the same cards as iPhone widgets. On the way, the iPhone's connection banner shrinks to a bar that appears only when something needs you.

**Duration:** about 5–6 weekends. **Depends on:** nothing unfinished (7.1 can start at once). **Decision:** [ADR-0025](../architecture/decisions/0025-vault-overview-and-iphone-cache.md). **Specs:** [UX: Mac ▸ Home](../product/04-ux-mac.md#home), [UX: iPhone ▸ Home, Status bar, Widgets](../product/05-ux-iphone.md), [companion protocol `overview.get`](../architecture/companion-protocol.md#4-methods), requirements FR-H-01..06 and FR-iOS-06.

**Order:** 7.1 → 7.2 → 7.3 and 7.4 (either order) → 7.5. Each step ships on its own; the Mac and iPhone apps are updated together.

## 7.1 The iPhone's status bar · ½ weekend
Replaces the banner at the top of Capture, Search and the Inbox ([UX: iPhone ▸ Status bar](../product/05-ux-iphone.md#status-bar)).
- [x] **The bar** above the tab bar, one for the whole app: iOS 26's `tabViewBottomAccessory` where it can be hidden when there's nothing to say (check on the device whether 26.0 can; otherwise, and on iOS 18–25, a bar of our own just above the tab bar). Nothing while connected.
  - *Found (iOS 27 SDK, 2026-10-25):* 26.0 has only `tabViewBottomAccessory(content:)`, with no way to turn it off once set; 26.1 added `tabViewBottomAccessory(isEnabled:content:)`. So the accessory from 26.1, and on iOS 18–26.0 a bar of our own as a bottom `safeAreaInset` of each tab, which leaves the large titles and the search field alone. The accessory's content needs a view of its own that reads the state itself: built inline in the tab view's body, it kept its first text ("Mac not reachable" without "· 2 waiting"). Debug builds take `-FunesOwnStatusBar YES` to try ours on a newer iOS, and `-FunesConnection <state>` (connected, unreachable, localNetworkOff, failed, revoked) to show a state without a Mac. Checked in the iOS 27 simulator: connected, unreachable, not paired and the demo, with the accessory and with our own bar, and the status sheet from the bar and from Why?. In the simulator, tapping the middle of the bar (its words) often didn't open the sheet while the icon, the left edge and the button did; on an iPhone 13 mini (iOS 27.0.1) every tap works, so it was the simulator's (2026-10-25).
- [x] **States** from FunesPhone's `BannerState` (unchanged): Connecting (only after 2 s), Mac not reachable · N waiting [Why?], Local Network access is off [Fix], Can't connect to your Mac [Why?], Pair with your Mac to start [Pair], Removed from Funes on your Mac [Pair Again], Back online · N captures sent (3 s), Demo vault: not your data [Leave Demo] (always). A 2-second debounce before showing any state.
- [x] **Tapping the bar** opens the status sheet (today's Why sheet: which Mac, last reached, the queue with Send Now, the hints, Try Again); the bar's button acts directly.
- [x] **Remove** `BannerSection` from Capture, Search and the Inbox; their full-page explanations (`VaultUnavailableView`) stay. Try Demo moves to Capture's (later Home's) pairing card.
- [x] VoiceOver (one element, the action as a custom action, one announcement per change), Reduce Motion (fade), Dynamic Type; string catalog.
- [x] Tests in FunesPhone for the debounce and the "Back online" transition; the screenshot scenes and the App Store screenshots plan updated (the DEMO label moves to the bar).
- [x] When the code lands: README, docs, CHANGELOG.

## 7.2 The overview · 1–1.5 weekends
[ADR-0025](../architecture/decisions/0025-vault-overview-and-iphone-cache.md).
- [x] **`VaultOverview`** in FunesCore: one read for a range (30 days, 12 weeks, 12 months) with the aggregates of ADR-0025 §1. Counts only; a test asserts no memory text or title can appear in it. *(`VaultStore.overview(_:now:calendar:)`, the type in FunesProtocol so the phone shares it; `OverviewTests`.)*
- [x] Days in the user's time zone; 12 weeks and 12 months grouped by week and month; "this week" and the sentence's numbers. *(Plus `rhythm`, 84 days whatever the range, for the Rhythm card and widget.)*
- [x] **Benchmark** on a 10,000-memory fixture vault: under 50 ms, or add the two indexes in a migration (with its fixture test). *(`OverviewBenchmarkTests`: 10,000 memories, 8,000 delivered requests with about 24,000 items, 2,500 others, each with a 20-memory candidate snapshot. Without indexes 86 ms (30 days), 90 ms (12 weeks), 105 ms (12 months); with `v5_overview_indexes`, five covering indexes (storage §3), 11.5, 13.7 and 36.0 ms (40–45 ms for 12 months while the Mac was busy). CPU time at user-interactive QoS, best of 7, M1, 2026-10-25. It runs alone in test.sh, not on CI. `migratesAVersion4Vault` is the fixture test.)*
- [x] **`overview.get`** in FunesCompanion, logged as `overview_viewed`; `CompanionClient` method and a router test. *(`overviewIsCountsOnly`; the client's `overview(_:)` on `CompanionCalling`, safe to resend.)*
- [x] **`OverviewCache`** in FunesPhone: `overview.json` in the App Group, atomic writes, `completeUntilFirstUserAuthentication`; deleted on unpair, revocation and leaving the demo. Tests. *(One answer per range; `OverviewModel` keeps it current, wired into `PhoneModel`'s refresh. `OverviewCacheTests`, and `overviewIsCachedWithoutText` through the real Mac.)*
- [x] **Demo:** 12 weeks of sample daily counts and agent deliveries in `demo-vault.json`, so the demo's Home and widgets have something to show. *(With sample vault totals, since the 20 browsable memories would make an empty chart.)*

## 7.3 Mac Home · 1.5 weekends
[UX: Mac ▸ Home](../product/04-ux-mac.md#home).
- [x] **Home** at the top of the sidebar (⌘1; the other shortcuts move down one); the main window and Open Funes Vault open on it. *(Reopening from the Dock with the window closed too. The setup checklist moved from the Vault to the top of Home.)*
- [x] **Composer:** focused on appearing; ⏎ saves a capture (the capture box's behaviour and secret-scanner error, one shared view), ⌘⏎ opens Vault searching for the text. *(`CaptureField` and `CaptureSaver`: one field, footer and save path for the box and Home; a save that fails after the text was let go puts it back with the reason, in the box or on Home.)*
- [x] **Dictation:** a mic in the composer and in the capture box (⌥⌘M), with SpeechAnalyzer; `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` and the `com.apple.security.device.audio-input` entitlement. *(`DictationTranscriber`, progressive short dictation, in the user's language when it's supported, the model fetched on first use; macOS 26 and later, with no mic on macOS 15. Not yet tried by voice: the development runs were unsigned, and the first use asks for access.)*
- [x] **Pulse card** with Swift Charts: the sentence; in (by source) above the line, out (by agent, top four and Other) below, refused dots; 7 days · 30 days · 12 weeks · 12 months, remembered; hover for a day's breakdown, click for Activity filtered to that day (a refused dot: Problems). *(7 days is the last week of the 30-day read, so `VaultOverview` is unchanged. In counts by source only, so the hover says "2 Agents", not which agent. Activity gained a period focus, "Showing Tue 21 Oct only".)*
- [x] **Cards:** Memories (total and growth), Sensitivity (vault and shared), Rhythm (12 weeks), Who reads your vault (top three); each opens its filtered place. The status line (Inbox waiting, last tidy-up). *(`OverviewInsights` in FunesCore works out the range's buckets, the top agents, the growth line, the grid, the busiest weekday and the streak, with tests. Rhythm opens Activity ▸ Suggestions, since Activity has no Changes filter; Sensitivity opens the Vault on the level its caption names first; with 7 days, its Shared bar is the last 30 days, which the overview has.)*
- [x] **Empty states:** a new vault, no agents yet, nothing this week.
- [x] Fits the default window size without scrolling; scrolls at the minimum, with the cards in two rows.
- [x] VoiceOver chart descriptor (audio graph) and per-day labels; Reduce Motion; string catalog; UI snapshots (`home`, `home-min`, `home-empty`, light and dark). *(Plus `home-checklist`, where `vault-checklist` was. The sample data gained 12 weeks of history, so the chart has something to draw. Checked on a development vault, 2026-10-25: a capture from the composer by button and by ⏎ reached the Inbox with "Saved to Inbox", an API key showed the scanner's error, ⌘⏎ searched the Vault, hover showed a day's breakdown, a click opened that day in Activity and a refused dot its Problems, and the range was remembered.)*
- [x] When the code lands: README (new screenshot), docs, CHANGELOG.

## 7.4 iPhone Home · 1 weekend
[UX: iPhone ▸ Home](../product/05-ux-iphone.md#home-tab).
- [ ] **Home** replaces the Capture tab (where the app opens; the Control and "Remember in Funes" open it). Everything Capture had stays: the composer, Waiting for you, Recent captures.
- [ ] Order: title ("Good afternoon"), composer, Waiting for you, Pulse card (7 / 30 days, finger scrubbing with a light haptic per day), Memories · Sensitivity · Rhythm tiles, Who reads your vault, Recent captures (five, then Show All).
- [ ] Taps: tiles to Search (newest, or filtered), Rhythm and the Pulse card to a sheet with the longer ranges.
- [ ] **States:** live when connected; the cache dimmed with "As of 10:42" while the Mac is away; a Pair with your Mac card (with Try Demo) in place of the charts when not paired; demo data in the demo; a new vault's empty states.
- [ ] Shared chart views in `Apps/FunesShared`, so the widgets draw the same thing.
- [ ] VoiceOver, Dynamic Type, Reduce Motion; string catalogs; screenshot scene `home` (and the App Store set's first shot).
- [ ] When the code lands: PRIVACY.md (the overview cache), the App Store privacy notes, README, docs, CHANGELOG.

## 7.5 iPhone widgets · 1 weekend
[UX: iPhone ▸ Widgets](../product/05-ux-iphone.md#widgets). First set: **Pulse, Remember and Rhythm**.
- [ ] Widgets in the `FunesIntents` bundle (next to the Control), reading `OverviewCache` through one timeline provider; a midnight entry moves the days along.
- [ ] **Pulse** (medium): the week's numbers and the 14-day in/out chart. **Remember** (small): Remember and 🎙 buttons (`OpenCaptureIntent`, typing or dictating). **Rhythm** (small: 6 weeks; medium: 12 weeks and the streak).
- [ ] The app reloads timelines after every cache write; the background refresh (`com.funesvault.ios.deliver`) also fetches the overview when the Mac answers.
- [ ] "as of" after an hour, dimmed after a day; Not paired and Demo states; agent names `.privacySensitive()`.
- [ ] Later, not in this step: Memories, the large Funes widget, Pulse large, Lock Screen widgets.
- [ ] When the code lands: README, docs, CHANGELOG.

## Exit criteria
- The author uses Home on both devices for a week; the Mac opens on it, and captures made from it reach the Inbox exactly as from the capture box.
- The iPhone shows nothing in its headers while connected; every banner state has its bar, and Demo is always labelled.
- `overview.get` and the cache never carry memory text or titles (tests); Home and the widgets show the cache with "As of" while the Mac is away.
- Pulse, Remember and Rhythm on the author's Home Screen for a week, refreshed without opening the app at least daily when the Mac is reachable.
