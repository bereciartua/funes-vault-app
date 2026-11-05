# App Store screenshots plan: Funes Vault for iPhone

**Size:** App Store Connect's main iPhone slot (2026: "iPhone with Dynamic Island (medium display)") takes the 6.1" or 6.3" sizes, 1179 × 2556 or 1206 × 2622, and scales them for other iPhones, so one set is enough. The script captures at 6.9" (1320 × 2868, iPhone 17 Pro Max simulator) and also writes 1206 × 2622 copies, the same proportions, to `6.3-inch/`; those are the ones uploaded for 0.2.0. The app is iPhone only (`TARGETED_DEVICE_FAMILY = 1`), so no iPad set; the iPhone Duo slot becomes required from April 2027 for builds made with the iOS 27.1 SDK. Light appearance, English (U.S.).

**Data:** demo mode (**Try Demo** on Home), whose sample vault (`Packages/FunesPhone/Sources/FunesPhone/Resources/demo-vault.json`) was written for this: no real names or data. The orange DEMO label stays in the shots, so they show exactly what a reviewer sees: from v0.4 (task 7.1) it's the status bar above the tab bar ("Demo vault: not your data", **Leave Demo**), no longer a banner at the top of each tab. Status bar: 9:41, full battery and signal (`xcrun simctl status_bar booted override --time 9:41 --batteryLevel 100 --cellularBars 4 --wifiBars 3`).

| # | Scene (`-FunesScreenshot`) | Screen | Caption (≤ 40 characters) |
|---|---|---|---|
| 1 | `home` | Home: the composer, "Waiting for you" (three requests) and the Pulse card (from v0.4, task 7.4; before, `capture`: Capture with a typed thought) | Capture anywhere. See what agents read. |
| 2 | `share` | The Share panel: rows ticked, one under "Also matched, less closely", the withheld line | See exactly what an agent would get. |
| 3 | `access` | The access panel: "Codex wants to read Health" | Answer agents from your phone. |
| 4 | `search` | Search results for "swift" | Search your vault on the Mac. |
| 5 | `inbox` | The Inbox's three suggestions | Review what agents suggest. |
| 6 | `save` | The Save panel: "Cursor suggests a memory" | Nothing is saved without you. |

Captions go on the image (simple text above a device-free screenshot, in the site's colours), or the screenshots go up plain: both are allowed. An optional App Preview video isn't planned for v0.2.

**Not shown:** the lock-screen notification. It needs a real Mac and CloudKit, so it's the screen recording attached to the App Review notes instead (README, step 9).

**Capture:** `sh scripts/app_store_screenshots.sh` builds the Debug app for an iPhone 17 Pro Max simulator (made if missing), launches it once per scene with `-FunesScreenshot <scene>` (`Apps/FunesiOS/ScreenshotScene.swift`, Debug builds only: demo mode opened on that screen, nothing tapped) and writes `build/app-store-screenshots/<n>-<scene>.png` at 1320 × 2868, with 1206 × 2622 copies in `6.3-inch/`. They stay out of git; upload the `6.3-inch/` copies in App Store Connect ▸ the version ▸ iPhone (the main slot; it scales them for other iPhones). *2026-10-22: all six captured and checked (`FUNES_SHOT_WAIT=40` on a heavily loaded Mac). Shot 6 first showed a tall empty space under the Save panel's Kind row, an iOS 27 layout quirk of `LabeledContent` with a `Label`; `KindRow` fixed it there and in the memory detail and Inbox suggestion.*

## 0.5.0: direction A, "Orange ground"

From 0.5.0 the screenshots are one panorama in funesvault.com's look, cut into seven panels, made with the generator in the maintainer's launch-visuals drafts (not in the repo) from this script's captures plus the Pulse widget on the Home Screen. Uploaded on 2026-11-04 to App Store Connect's required **6.3"** slot (iPhone with Dynamic Island, medium display: 1206 × 2622, the 1320 × 2868 renders scaled down); no other size has its own set, so they scale.

| # | Headline | Screen |
|---|---|---|
| 1 | Funes Vault · Give AI agents your memory. *Not all of it.* | `home` |
| 2 | Ask your vault. See the source. | `search-answer` |
| 3 | Untick anything before it goes. | `share` |
| 4 | Answer agents from your phone. | `access` |
| 5 | Agents suggest. You stamp. | `inbox`, with an APPLY stamp |
| 6 | Remember from your Home Screen. | The Pulse widget (by hand) |
| 7 | Open one eye. Things it doesn't have. Free and open source. | none |

*2026-11-04:* on this Mac `FUNES_SHOT_WAIT=60` was needed (at 25 s, three scenes were blank and Home's tiles still loading), and the `save` scene showed Home without its sheet even at 60 s. In demo mode on the 6.9" simulator the DEMO bar covers part of Home's Memories and Rhythm tiles and pushes Sensitivity and Who reads below the tab bar.
