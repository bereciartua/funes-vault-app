# App Store privacy: Funes Vault for iPhone

**Label: Data Not Collected.** Task 5.7; [security and privacy §5](../../architecture/security-and-privacy.md#5-everything-that-can-leave-the-mac), [ADR-0019](../../architecture/decisions/0019-cloudkit-doorbell-for-iphone-approvals.md), [PRIVACY.md](../../../PRIVACY.md#funes-vault-for-iphone).

## The App Privacy questionnaire (App Store Connect ▸ App Privacy)
- **"Do you or your third-party partners collect data from this app?"** No.
- **Privacy Policy URL:** `https://funesvault.com/privacy/`.
- Nothing else to fill in; App Store Connect then shows "Data Not Collected". Publish it.

## Why "No" is right
Apple counts data as *collected* when it's sent off the device in a way that lets the developer or a partner access it for longer than it takes to serve the request. Funes Vault for iPhone sends:

| What | To | Why it isn't collection |
|---|---|---|
| Captures, searches, edits, Inbox and approval answers | The user's own Mac, end to end encrypted (companion protocol §3) | The user's device, not the developer's or a partner's. No server of ours exists |
| Nothing (the phone only subscribes); the Mac writes a `Doorbell` record with a random tag | The user's own **private** CloudKit database | The developer can't read a user's private database. The record holds no user data, and is deleted after the request |
| APNs registration | Apple | Apple's service; Apple-controlled data isn't the developer's to declare |
| Crash reports, if the user shares analytics with developers; TestFlight feedback | Apple, which may pass them on | Collected by Apple under its own consent; not declared by apps |

No analytics, advertising, tracking or third-party SDKs are in the app or its extensions (FunesPhone and FunesProtocol depend only on system frameworks).

## The privacy manifests
`Apps/FunesiOS`, `Apps/FunesShareExtension`, `Apps/FunesIntents` and `Apps/FunesNotifications` each have a `PrivacyInfo.xcprivacy` (the folders are synchronized, so it's in each bundle's resources): no tracking, no tracking domains, no collected data types, and the required-reason APIs below. `scripts/ios_release.sh` checks every bundle in the archive has one.

**Required-reason APIs, checked 2026-10-22** with `nm -u` on the built app, its debug dylib and each extension, for the symbols of Apple's five categories (`NSUserDefaults`; `NSFileCreationDate`, `NSFileModificationDate`, `NSURLContentModificationDateKey`, `NSURLCreationDateKey`, `getattrlist`, `stat`/`fstat`/`lstat`/`fstatat`; `systemUptime`, `mach_absolute_time`; `NSURLVolumeAvailableCapacity…Key`, `statfs`, `statvfs`; `activeInputModes`):

| Category | Used by | Reason |
|---|---|---|
| `NSPrivacyAccessedAPICategoryUserDefaults` | All four (FunesPhone's `CaptureLaunch`: the Control's "open Capture" request, in the App Group's defaults `group.com.funesvault`) | `1C8F.1`: read and write information shared only within the app's App Group |

Nothing else matched. Elapsed times use Swift's `ContinuousClock`, which isn't on Apple's list; SQLite and Network.framework are system libraries. **Re-run the check when a dependency or a file-attribute, uptime, disk-space or keyboard API is added:**
```bash
for b in build/DerivedData/Build/Products/Debug-iphoneos/FunesiOS.app/FunesiOS.debug.dylib build/DerivedData/Build/Products/Debug-iphoneos/FunesiOS.app/PlugIns/*.appex/*.debug.dylib; do nm -u "$b" | grep -E "NSUserDefaults|CreationDate|ModificationDate|_getattrlist|_f?stat|_lstat|mach_absolute_time|AvailableCapacity|_statv?fs|activeInputModes"; done
```

## Permissions (Info.plist)
Local Network (`NSLocalNetworkUsageDescription`, Bonjour `_funes._tcp`), Camera (the pairing code), Microphone and Speech Recognition (dictation, on the iPhone), notifications (asked once approvals are on). Background modes: `fetch` only, for `BGAppRefreshTask` `com.funesvault.ios.deliver`.
