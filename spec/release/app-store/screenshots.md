# App Store screenshots plan: Funes Vault for iPhone

**Size:** 6.9" iPhone portrait, 1320 × 2868 (iPhone 17 Pro Max simulator). App Store Connect scales it for smaller iPhones, so one set is enough; the app is iPhone only (`TARGETED_DEVICE_FAMILY = 1`), so no iPad set. Light appearance, English (U.S.).

**Data:** demo mode (**Try Demo** on Capture), whose sample vault (`Packages/FunesPhone/Sources/FunesPhone/Resources/demo-vault.json`) was written for this: no real names or data. The orange DEMO banner stays in the shots, so they show exactly what a reviewer sees. Status bar: 9:41, full battery and signal (`xcrun simctl status_bar booted override --time 9:41 --batteryLevel 100 --cellularBars 4 --wifiBars 3`).

| # | Screen | How to get there | Caption (≤ 40 characters) |
|---|---|---|---|
| 1 | Capture with "Waiting for you" (three requests) and a typed thought | Capture tab, type "Ask the team about Friday's demo" | Capture anywhere. It waits for your Mac. |
| 2 | The Share panel: rows ticked, one under "Also matched, less closely", the withheld line | Tap "Claude Code wants 4 memories" | See exactly what an agent would get. |
| 3 | The access panel | Tap "Codex wants more access" | Answer agents from your phone. |
| 4 | Search results for "swift" | Search tab | Search your vault on the Mac. |
| 5 | A memory's detail with provenance | Tap "Swift 6 with strict concurrency" | Edit, archive, or delete. |
| 6 | The Inbox, mid-swipe to Save | Inbox tab | Review what agents suggest. |

Captions go on the image (simple text above a device-free screenshot, in the site's colours), or the screenshots go up plain: both are allowed. An optional App Preview video isn't planned for v0.2.

**Not shown:** the lock-screen notification. It needs a real Mac and CloudKit, so it's the screen recording attached to the App Review notes instead (README, step 9).

**Capture:** `xcrun simctl io booted screenshot <n>.png` per screen, kept out of git (they're large); upload in App Store Connect ▸ the version ▸ iPhone 6.9" Display.
