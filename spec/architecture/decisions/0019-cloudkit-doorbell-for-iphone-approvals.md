# ADR-0019: A CloudKit "doorbell" wakes the iPhone for approvals (no data in iCloud)

**Status:** Proposed · 2026-10-20 · waiting for the delivery-time measurement ([spike](../../../spikes/cloudkit-doorbell/README.md), [results](../../plans/spike-results.md#q24-cloudkit-doorbell-delivery-time)). **Amends** [ADR-0003](0003-mac-is-the-only-source-of-truth.md) (no CloudKit). Decides [Q24](../../plans/open-questions.md).

**Context.**
- **Approvals from the iPhone are the main reason for the companion** ([Q16](../../plans/open-questions.md), [FR-iOS-12](../../product/03-requirements.md)). When a Share, Save or access request starts waiting, the phone must show a notification, even locked and with Funes closed.
- **Only Apple's push service (APNs) can wake a locked iPhone.** Something has to ask APNs to send the push:
  - **The Mac can't send it itself.** That would need the team's APNs signing key (`.p8`) inside the Mac app. It's a team-wide secret, and anyone could extract it from the app.
  - **A relay of ours** could hold the key, but that's a server: [ADR-0003](0003-mac-is-the-only-source-of-truth.md) says "no server of ours".
  - **CloudKit** already sends pushes for subscriptions on the user's own private database, with Apple holding the keys. ADR-0003 rules out CloudKit, but for *replication*, and it named this exact exception: "CloudKit could later be used only as a 'doorbell' with no memory data".
- **The timing that matters:** an agent waits 45 s in-call ([Q10](../../plans/open-questions.md)), then the request stays on the 15-minute pending list ([access policy §3.9](../../domain/access-policy.md#39-after-15-minutes)). A push that usually arrives in a few seconds lets the user answer inside the in-call wait; a slower one still lets them answer from the pending list.
- **Rules from the spec that don't change:** no memory text, titles, task or agent name go through Apple or anyone else (FR-iOS-12). The details travel only over the companion channel, end to end encrypted ([ADR-0011](0011-app-layer-encryption-for-companion.md)). Approvals work the same on every channel, and the only auto-approve is each agent's Ask before sharing / saving switch ([ADR-0018](0018-remote-access-in-v0.1.md)).

**Decision** *(proposed; final once the measurement passes)*.
1. **A doorbell record in the user's private CloudKit database.** Container `iCloud.com.funesvault`, record type `Doorbell`, default zone:
   - the **record name** is a fresh random 128-bit id for each ring. It isn't the request id: the Mac keeps the mapping in memory only while the request waits;
   - one field, **`tag`**: a random per-device value, given to the phone over the companion channel when approvals are turned on for it, so the Mac rings only the devices that have approvals on;
   - nothing else. No text, no counts, no names, no agent.
2. **Each phone subscribes to its own tag.** A `CKQuerySubscription` on `Doorbell` with `tag == <its tag>`, firing on creation, with:
   - a fixed alert, "You have a request", set on the phone when it subscribes (localized there);
   - `shouldSendMutableContent`, so the **notification service extension** runs on the phone. It fetches the panel over the companion channel and rewords the alert there ("Claude wants to share 3 memories"). If the Mac isn't reachable, it says so and keeps the generic text;
   - no desired keys, so the push carries only the record name and the subscription's ids;
   - Time Sensitive interruption level, if the spike shows it's honoured, so a Focus doesn't hide a 45-second wait.
3. **The ring is only a wake-up.** Correctness never depends on it:
   - the phone answers through the companion channel. The answer is bound to the request id and its snapshot revision, single use, with the same 15-minute and invalidation rules; the first answer wins on the Mac or the phone (task 5.6);
   - a late or lost push means the user answers on the Mac, or opens the phone app and sees the pending request;
   - the Mac deletes a doorbell record once its request is answered, expires or is invalidated, and on launch deletes any left over. None outlives the 15 minutes.
4. **Needs the same Apple Account on the Mac and the iPhone, with iCloud on.** Without it, approvals work as before: on the Mac, or in the phone app when it's opened. Settings ▸ iPhone says why notifications are off.
5. **What Apple can see:** that the user's devices exchanged a doorbell record at a given time (how often requests wait), the random tag and record names, and the container. Nothing about memories, agents or tasks. The records live in the user's private database, which we can't read.
6. **If the measurement fails** (rings usually slower than the in-call wait, or missed), the fallback is an APNs relay, recorded as its own ADR amending "no server of ours". Approvals still work through the pending list until then.

**Consequences.**
- **The Mac app gets CloudKit:** the iCloud entitlement with the container, and a Developer ID provisioning profile embedded in the app. That's new for the Mac release pipeline (a profile to keep current, and the CloudKit production environment). The Mac app never subscribes and never receives pushes.
- **New iPhone identifier:** the notification service extension, `com.funesvault.ios.notifications`, with the App Group and the companion keys' Keychain access group. The app gets Push Notifications, iCloud (CloudKit) and Time Sensitive Notifications.
- **The record type must be deployed to CloudKit production** before the first TestFlight build, and can't be removed afterwards. Keep it this small.
- **Privacy wording:** still "Data Not Collected". The developer can't access the private database, and the record holds no user data. When 5.6 ships, `PRIVACY.md` and [security and privacy](../security-and-privacy.md) name CloudKit as the doorbell's channel.
- **ADR-0003 stands otherwise:** no replication, no cloud copy of the vault, no CKSyncEngine.

**Alternatives considered.**
- **APNs through a small relay of ours:** dependable timing and full control of the push (priority, interruption level, collapse ids). But it's a server to run, secure and pay for, it sees every ring's timing and IP addresses, and a team APNs key would live on it. Kept as the fallback.
- **Local Push Connectivity (`NEAppPushProvider`):** the phone keeps its own connection to the Mac on chosen Wi-Fi networks, with no Apple servers. It doesn't work on cellular or Tailscale, and needs the Network Extension entitlement. Maybe later, as a complement on home Wi-Fi.
- **Background refresh polling:** iOS decides when it runs, often minutes to hours apart. Too slow for a 45-second wait.
- **Sending a message to oneself** (Messages, Mail): it's hacky, needs Automation permissions, and puts text in another service.
