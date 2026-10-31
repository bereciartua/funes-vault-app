# Funes Vault for iPhone on the App Store

Task 5.7 of [Phase 5](../../plans/phase-5-iphone-companion.md). What goes into App Store Connect, as files to paste from, and the steps only the maintainer can take there.

| File | What |
|---|---|
| [`en-US/name.txt`](en-US/name.txt) · [`subtitle.txt`](en-US/subtitle.txt) | "Funes Vault" · "Private memory for AI agents" |
| [`en-US/promotional-text.txt`](en-US/promotional-text.txt) · [`description.txt`](en-US/description.txt) · [`keywords.txt`](en-US/keywords.txt) | The version page's texts |
| [`en-US/support-url.txt`](en-US/support-url.txt) · [`privacy-url.txt`](en-US/privacy-url.txt) · [`marketing-url.txt`](en-US/marketing-url.txt) | `https://funesvault.com/support/`, `/privacy/`, `/` (`site/support`, `site/privacy`, `site/index.html`) |
| [`en-US/review-notes.txt`](en-US/review-notes.txt) | App Review notes: the Mac requirement and how to enter demo mode |
| [`privacy.md`](privacy.md) | The App Privacy answers ("Data Not Collected") and the privacy manifests' audit |
| [`screenshots.md`](screenshots.md) | The screenshots plan |

`sh scripts/check_app_store_metadata.sh` (run by `scripts/test.sh`) keeps the texts within App Store Connect's limits. Keywords avoid other companies' trademarks (App Review guideline 2.3.7); the description names the agents Funes works with only as compatibility.

## Settings

| Setting | Value |
|---|---|
| Bundle id · SKU · Apple ID | `com.funesvault.ios` · `FUNESVAULT-IOS` · 6823794639 |
| Primary language | English (U.S.) |
| Category | Productivity; secondary Developer Tools |
| Age rating | 4+ (every questionnaire answer "None" or "No"; no web browsing, no user-to-user content) |
| Price · availability | Free · all countries and regions; not on Apple silicon Macs or Apple Vision Pro (the Mac has its own app; neither is tested) |
| Content rights | Contains no third-party content |
| Version | The project's `MARKETING_VERSION` (0.2.0 for v0.2; 0.5.0, from build 11, for v0.3 to v0.5), or `FUNES_IOS_VERSION` for iPhone builds ahead of the Mac's release; the build number is `CURRENT_PROJECT_VERSION`, or `FUNES_IOS_BUILD` for another upload of the same version |
| Release | Manually, after the Mac's v0.2 (with Settings ▸ iPhone shown in Release) is out through Sparkle: without it nobody can pair. 0.2.0's builds 8 to 10 already have Home and About you, which need the Mac's 0.5.0 (`overview.get`, `calledName`), so the Mac's 0.5.0 goes out with or before the iPhone's 0.2.0, and the iPhone's 0.5.0 is submitted after that |
| Sign-in for App Review | Not required: demo mode ([review notes](en-US/review-notes.txt)) |

## Building
```bash
sh scripts/ios_release.sh
```
Archives the Release configuration for a generic iPhone with automatic signing for team `JVNJ326L7B`, then checks every bundle's version, build and privacy manifest, and the app's entitlements. `--export` adds an `.ipa` signed for App Store Connect in `dist/ios/` (and checks it isn't debuggable, has `aps-environment` production and an Apple Distribution signature); `--upload` sends it to App Store Connect. `--allow-provisioning-updates` lets Xcode create the Apple Distribution certificate and App Store profiles the first time. An App Store Connect API key (`FUNES_ASC_KEY`, `FUNES_ASC_KEY_ID`, `FUNES_ASC_ISSUER`) can stand in for the Xcode account. *2026-10-22: the archive passes with this Mac's development profiles; the export waits for the maintainer (step 2).*

## The maintainer's steps in App Store Connect, in order
*Done 2026-10-22, in the browser with the maintainer signed in:* subtitle, categories, content rights and the 4+ age rating (step 1); `Doorbell` checked in CloudKit Production (step 3); App Privacy published as Data Not Collected with the policy URL (step 4); on the 1.0 version page, now 0.2.0, the promotional text, description, keywords, support and marketing URLs, copyright and manual release (step 8). Pricing and Availability: Free ($0.00) in all 175 countries or regions, and not offered on Apple silicon Macs or Apple Vision Pro. The account is declared a non-trader under the EU's Digital Services Act. Distribution signing set up (cloud-managed Apple Distribution certificate and App Store profiles, created by `--allow-provisioning-updates`), and **0.2.0 (5) uploaded** from PR #40's branch (then **0.2.0 (8)** on 2026-10-26 from PR #71's branch, with About you; 9 was taken by an upload not recorded here; **0.2.0 (10)** on 2026-10-27 from PR #73's branch, with Home's one-line composer and chart scrolling; then **0.5.0 (11)** on 2026-10-27 from `main` at 10cbe38, the first build of the next version, for TestFlight only while 0.2.0 waits for review; **0.5.0 (12)**, with `FUNES_IOS_BUILD=12`, the same day from PR #79's branch, with the app's own version in Settings; **0.5.0 (13)**, with `FUNES_IOS_BUILD=13`, on 2026-10-28 from PR #81's branch at f16865c, with no iPhone changes since 12; **0.5.0 (14)**, with `FUNES_IOS_BUILD=14`, the same day from PR #83's branch at 51b87c9, with Search no longer showing Mac not reachable while typing; **0.5.0 (15)**, with `FUNES_IOS_BUILD=15`, on 2026-10-29 from PR #84's branch at 74c6919, with search snippets that show the matching passage; **0.5.0 (16)**, with `FUNES_IOS_BUILD=16`, on 2026-10-30 from PR #84's branch at 02d4b3a, with Search answers; **0.5.0 (17)**, with `FUNES_IOS_BUILD=17`, the same day at 64ee67e, with automatic answers and 10 results read; **0.5.0 (18)**, with `FUNES_IOS_BUILD=18`, the same day at beb0fd7, keeping the last answer when a memory opens; **0.5.0 (19)**, with `FUNES_IOS_BUILD=19`, on 2026-10-31 from PR #88's branch at dc76749, with Home as widget-like tiles and a title without the name; **0.5.0 (20)**, with `FUNES_IOS_BUILD=20`, the same day from PR #89's branch at cb14c6a, with Home's composer no longer refocusing after a widget tap); TestFlight group "Funes Internal" (automatic distribution, the maintainer as tester). *Still open:* App Review contact details and notes (that section saves only with contact details), screenshots, TestFlight's Test Information, the screen recording (step 9) and submitting (step 10).

Anything in the Apple Developer account or App Store Connect is the maintainer's to do or approve. None of these needs a credential in the repo.

1. **Check the app record** (Apps ▸ Funes Vault). The name was reserved on 2026-10-16 with `com.funesvault.ios` ([Phase 0](../../plans/phase-0-spikes.md)). Set the SKU, primary language, category and content rights as above. *Keep the name:* a first build has to be uploaded before about 14 April 2027.
2. **Signing for distribution.** Run `sh scripts/ios_release.sh --export --allow-provisioning-updates` (or say go, and it's run for you): Xcode, signed in to the team, creates an Apple Distribution certificate (or uses cloud signing) and App Store profiles for the app and its three extensions. The App IDs already have their capabilities (iCloud with `iCloud.com.funesvault`, Push Notifications, Time Sensitive Notifications and the App Group on the app; the App Group on each extension).
3. **CloudKit Production.** In the CloudKit Console, `iCloud.com.funesvault` ▸ Production: check that the `Doorbell` record type (only `tag`; `tag` and `recordName` queryable) is there, as deployed on 2026-10-21. The Development reset of 2026-10-22 didn't touch Production. A TestFlight or App Store build uses Production.
4. **App Privacy:** "No, we do not collect data from this app", the privacy policy URL, then **Publish** ([privacy.md](privacy.md)).
5. **Export compliance:** the app uses only Apple's CryptoKit and HTTPS (review notes, last section), which is exempt. `ITSAppUsesNonExemptEncryption = NO` is in `Apps/FunesiOS-Info.plist` (decided 2026-10-22), so builds don't wait on the question; `ios_release.sh` checks it.
6. **Upload the first build:** `sh scripts/ios_release.sh --upload` from a clean, tagged tree, with the version bumped for v0.2. Uploading needs the maintainer's go-ahead each time.
7. **TestFlight.** Create an internal group ("Funes Internal": the maintainer and anyone on the team), add the build, and fill in Test Information (beta app description, feedback email). For outside testers, an external group ("Funes Beta") goes through Beta App Review with the same [review notes](en-US/review-notes.txt). Run 5.8's manual matrix on the TestFlight build: it's the first one on CloudKit Production.
8. **Version page:** paste the [texts](en-US/), upload the [screenshots](screenshots.md), set the support, marketing and privacy URLs, and choose "Manually release this version".
9. **App Review information:** contact name, phone and email; "Sign-in required" off; paste [review-notes.txt](en-US/review-notes.txt). Attach a short screen recording of pairing with a Mac and answering a notification on a locked iPhone, since App Review can't do those without a Mac.
10. **Submit for review.** After approval, release it by hand once the Mac's v0.2 is out.
