# Spike: CloudKit doorbell delivery time (Q24)

Throwaway code for [Q24](../../spec/plans/open-questions.md) and [ADR-0019](../../spec/architecture/decisions/0019-cloudkit-doorbell-for-iphone-approvals.md). It measures how long a CloudKit "doorbell" takes to go from the Mac to a **locked** iPhone, against the 45 s in-call approval wait. Results go in [spike-results.md](../../spec/plans/spike-results.md#q24-cloudkit-doorbell-delivery-time). Nothing here ships.

| Target | Bundle id | What it does |
|---|---|---|
| `DoorbellMac` (macOS 15) | `com.funesvault.spike.doorbell` (spike only) | Saves `Doorbell` records to your private CloudKit database, once or N times on a timer. Listens on port **47639** for the phone's acknowledgements and times each ring on the Mac's clock. **Copy Results** puts a Markdown table on the clipboard |
| `DoorbellPhone` (iOS 18) | `com.funesvault.ios` | Subscribes to `Doorbell` records with its tag and shows the phone's log. **Test Mac** checks the phone can reach the Mac |
| `DoorbellNSE` | `com.funesvault.ios.notifications` | The notification service extension. It runs for every ring, also with the phone locked: logs the time, sends `POST /ack` to the Mac, and rewrites the alert ("Arrived 2.3 s after the Mac rang. Reached your Mac") |

**What it measures**, per ring:
- **Saved:** how long the Mac's CloudKit save took.
- **Reached the Mac:** from the start of the save until the extension's acknowledgement arrived, all on the Mac's clock. This is the number that matters: the time until the phone could fetch a panel from the Mac.
- **Phone clock:** when the extension ran, minus the Mac's `sentAt` from the push. Both clocks are synced by Apple, usually to well under a second. It's there for rings whose acknowledgement couldn't reach the Mac.
- Whether a locked phone's extension can reach the Mac over Wi-Fi or Tailscale at all, and whether the alert shows as Time Sensitive.

The record carries `tag`, `seq` and `sentAt`, and the subscription asks for `seq` and `sentAt` in the push, only to measure. The product's record carries only `tag`, and its push no fields ([ADR-0019](../../spec/architecture/decisions/0019-cloudkit-doorbell-for-iphone-approvals.md) §1–2).

## 1. Apple Developer portal (team JVNJ326L7B)

No keys, certificates or secrets go in the repo: CloudKit sends the pushes, so there's no APNs key to create. The project holds only the team id, as the main project does.

At [developer.apple.com/account](https://developer.apple.com/account) ▸ **Certificates, Identifiers & Profiles** ▸ **Identifiers**:

1. **Create the iCloud container.** **+** ▸ **iCloud Containers** ▸ Continue.
   - Description `Funes Vault`, identifier `iCloud.com.funesvault`. Register.
   - ⚠️ A container can never be deleted or renamed. The product uses this same one.
2. **`com.funesvault.ios`** (already registered): open it and, under **Capabilities**:
   - tick **iCloud**, choose **Include CloudKit support** (not "Compatible with Xcode 5"), then **Edit** ▸ tick `iCloud.com.funesvault` ▸ Continue;
   - tick **Push Notifications**. Leave its certificates alone: CloudKit doesn't need them;
   - tick **Time Sensitive Notifications**;
   - **App Groups** stays ticked with `group.com.funesvault`.

   **Save**, and confirm the warning about profiles (they're regenerated in step 6).
3. **Register `com.funesvault.ios.notifications`** (new; the product uses it too). **+** ▸ **App IDs** ▸ **App** ▸ Continue.
   - Description `Funes Vault Notifications`, **Explicit** bundle id `com.funesvault.ios.notifications`.
   - Capabilities: **App Groups**, then **Edit** ▸ `group.com.funesvault`. Register.
4. **Register the spike's Mac App ID `com.funesvault.spike.doorbell`.** **+** ▸ **App IDs** ▸ **App** ▸ Continue.
   - Platform **macOS**, description `Funes Doorbell Spike`, **Explicit** bundle id `com.funesvault.spike.doorbell`.
   - Capabilities: **iCloud**, **Include CloudKit support**, then **Edit** ▸ `iCloud.com.funesvault`. Register.
   - It's separate from `com.funesvault.mac`, so the spike never shares a bundle id, preferences or privacy permissions with the installed Funes Vault. Delete it after the spike. The real Mac App ID gets iCloud in task 5.6.
5. **Devices:** your iPhone and this Mac must be registered (Devices ▸ **+**). Xcode does it for you in step 7 if you let it.
6. **Profiles:** nothing to do by hand. The project uses automatic signing, so Xcode creates the development profiles for all three ids. To do it by hand instead: two **iOS App Development** profiles (`com.funesvault.ios`, `com.funesvault.ios.notifications`) and one **macOS App Development** profile (`com.funesvault.spike.doorbell`), each with your devices.
7. **CloudKit schema** at [icloud.developer.apple.com](https://icloud.developer.apple.com) ▸ CloudKit Database ▸ `iCloud.com.funesvault` ▸ **Development** environment:
   - **Schema** ▸ **Record Types** ▸ **+** ▸ `Doorbell`, with fields `tag` (String), `seq` (Int(64)), `sentAt` (Date/Time). Save.
   - **Schema** ▸ **Indexes** ▸ `Doorbell` ▸ **+** ▸ `tag` ▸ **Queryable**. Save. (The subscription filters on `tag`.)
   - **Don't deploy to Production.** The spike runs in Development only; the product's record type (just `tag`) is deployed in task 5.6.

## 2. Running it on your iPhone

**Before you start**
- The Mac and the iPhone are signed in to the **same Apple Account**, with iCloud on (iPhone: Settings ▸ your name ▸ iCloud).
- iPhone: **Developer Mode** on (Settings ▸ Privacy & Security ▸ Developer Mode; it restarts the phone).
- Both on the same Wi-Fi. For the cellular run, Tailscale on both.
- The installed Funes Vault can stay running: the spike uses its own bundle id on the Mac and port 47639.

**Install**
1. Open `spikes/cloudkit-doorbell/Doorbell.xcodeproj` in Xcode. Under **Signing & Capabilities**, each target should show team JVNJ326L7B and a profile with no errors.
2. Connect the iPhone. Choose the **DoorbellPhone** scheme and your iPhone, then **Run**. On the phone, tap **Allow Notifications** and allow them.
3. Choose the **DoorbellMac** scheme and **My Mac**, then **Run**. The window should say **iCloud available** and **Listening on port 47639**, and list the Mac's addresses. If macOS asks whether to accept incoming connections, allow it.

**Connect**
4. On the phone, type the Mac's **LAN** address from the Mac window, and tap **Test Mac**. Allow **Local Network** when asked. It should say "Reached the Mac", and the Mac's status line "The phone reached the Mac (test)".
5. Tap **Subscribe**. It should say `Subscribed to tag "spike"`.
6. With the app open, click **Ring once** on the Mac. Within seconds the phone shows "You have a request", reworded by the extension, and the Mac's table fills in.

**Measure** (keep the iPhone charging and untouched between rings)

| Run | Phone | Mac window | Rings |
|---|---|---|---|
| A | Locked, on Wi-Fi, app in the background | **20 rings every 90 s**, Start | 20 (~30 min) |
| B | Swipe the app away in the app switcher, then lock | 10 rings every 90 s | 10 |
| C | Wi-Fi off, cellular, Tailscale on both. Change the phone's Mac address to the Mac's **Tailscale** (100.x) one *before* locking | 10 rings every 90 s | 10 |
| D (optional) | Locked, with a Focus on (Do Not Disturb) | 3 rings every 60 s | 3: does the alert break through as Time Sensitive? |

After each run, click **Copy Results** on the Mac and save what it copied. Rings marked `missing` were either not delivered or couldn't reach the Mac: check the phone app's log (unlock, open it, pull to refresh, **Copy Log**). If it has the ring, the push arrived but the locked phone couldn't reach the Mac.

**Send back:** the copied results of each run, the phone log, the iPhone model and iOS version, and whether run D's alerts broke through the Focus.

**Clean up:** on the Mac, **Delete Records from iCloud**, then quit. Delete the app from the iPhone. Optionally delete the `com.funesvault.spike.doorbell` App ID. Keep the container and the other App IDs: the product uses them.

## Pass criteria (from ADR-0019)
- **Pass, CloudKit:** run A delivers all 20 rings, p90 ≤ 15 s and max ≤ 45 s; run B still delivers.
- **Marginal:** p90 between 15 and 45 s, or at most one ring missed. Keep CloudKit with the pending list as the backstop, and look at the relay again after real use.
- **Fail, relay:** p90 over 45 s, or more than one ring in 20 missed.

## Building without signing (CI-style check)
```bash
xcodebuild -project spikes/cloudkit-doorbell/Doorbell.xcodeproj -scheme DoorbellMac -destination 'generic/platform=macOS' -derivedDataPath build/doorbell CODE_SIGNING_ALLOWED=NO build
```
```bash
xcodebuild -project spikes/cloudkit-doorbell/Doorbell.xcodeproj -scheme DoorbellPhone -destination 'generic/platform=iOS' -derivedDataPath build/doorbell CODE_SIGNING_ALLOWED=NO build
```
