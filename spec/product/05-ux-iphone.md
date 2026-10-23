# UX: Funes Vault for iPhone (v0.2)

The iPhone app is a **thin client of the Mac's vault**. It captures anywhere, always. It searches, edits and reviews only while the Mac is reachable. It never stores the vault.

## Information architecture

```
Tab bar:  Capture · Search · Inbox · Settings
Extensions: Share extension · App Intent "Remember in Funes" · Control (Control Center / Lock Screen / Action button) · Notification service extension (approvals)
```

The app opens on **Capture**: the fastest path to the main job.

## States

| State | Banner (top of every tab) | Capture | Search / Inbox |
|---|---|---|---|
| Not paired | "Pair with your Mac to start" [Pair] | Works, queued locally until pairing | Disabled; offers **Try demo** |
| Connected | "Connected to Maya's MacBook Pro · Wi-Fi" | Sent immediately | Enabled |
| Unreachable | "Mac not reachable · 3 captures waiting" [Why?] | Queued | Disabled, with an explanation |
| Revoked by the Mac | "This iPhone was removed from Funes on your Mac" [Pair again] | Queued captures kept until the user decides | Disabled |
| Demo | "Demo vault: not your data" | Demo only | Demo data |

**"Why?" sheet:** "Your vault lives on your Mac. Search and review need the Mac to be awake and reachable on the same Wi-Fi, or through Tailscale. Captures are safe on this iPhone and will be sent automatically."

## Capture tab
- A large text field with the placeholder "What should Funes remember?" and a mic button for dictation (SpeechAnalyzer on iOS 26+, otherwise system dictation).
- **Remember** saves to the local queue instantly (haptic plus a "Saved" toast). It then tries to deliver.
- **Recent captures** list, showing each item's status: "Sent to Mac ✓", "Waiting", or "Blocked: looks like a secret". The phone runs the same secret scanner, so a secret is blocked before it's even queued.
- Optional before sending: category and sensitivity hint chips.

## Search tab
- A search field. Results come from the Mac, showing the title, a two-line snippet, category chips and a sensitivity badge.
- **Memory detail:**
  - full text, kind, categories, sensitivity, expiry and provenance;
  - **Edit**, **Archive** and **Delete**.
  - Edits are sent to the Mac and confirmed. A failed save shows an error, and the text is kept until it saves.
- Nothing is cached after leaving the screen, beyond in-memory state.

## Inbox tab
- Same cards as on the Mac: source, proposed fields, Save, Edit & Save, Reject (the [glossary](06-glossary.md)'s words).
- Swipe right to save, left to reject. Pull to refresh.
- **From v0.3** (Phase 6): pieces of a split input are ordinary suggestions, shown one per row with "Part of: <source>". Tidy-up cards (merge, split, conflict) and anything else the phone doesn't know yet show as one row, "N to review on your Mac", until a later iPhone update adds them. Saving a piece applies its own action (new, update, already saved, removes), never Keep both for everything.

## Approvals (FR-iOS-12)
When an agent's Share, Save or access request waits on the Mac, the Mac rings a CloudKit doorbell and this iPhone shows a notification, also locked ([ADR-0019](../architecture/decisions/0019-cloudkit-doorbell-for-iphone-approvals.md)).
- **The notification** is worded on the phone by the notification service extension, after it fetches the request from the Mac over the companion channel. It names the agent and the count or category, never memory text, titles or the task (the lock screen shows it):
  - "Claude Code wants 3 memories" · "Open to see exactly what would be shared."
  - "Cursor suggests a memory" (or "a correction") · "Open to save or discard it."
  - "Codex wants to read Work" (or "to suggest memories") · "Open to answer. The agent is waiting."
  - Answered first on the Mac: "Answered on your Mac". Past its time: "This request expired".
  - The Mac can't be reached in 10 s: "You have a request" · "Mac not reachable. Answer on your Mac, or open Funes when your Mac is reachable."
  - Time Sensitive, so a Focus doesn't hold it back.
- **Waiting for you:** the requests still waiting, at the top of Capture, soonest deadline first, with "Answer by 14:32"; the Capture tab's badge counts them. For a notification that was missed or dismissed.
- **The panel** opens from the notification or the list, as a sheet, with the same contents and words as the Mac's:
  - **Share:** "Claude Code wants 3 memories"; **Goes to** (with a Cloud badge for a cloud agent); **The agent says · not checked by Funes** (Task, Looking for, Purpose, Keeps what it gets, Shared with); **Your note** when set; the memories with checkboxes and sensitivity badges, each with its exact text (3 lines, then **Show All**), strong matches ticked and weaker ones unticked under **Also matched, less closely**; the withheld line ("2 more matched but can't go to this agent (…)"). **Share N** (prominent, needs one ticked) and **Deny**.
  - **Save:** "Save this memory?" (or "correction"), "From Claude Code. It's in your Inbox either way.", the memory with kind, categories and sensitivity, and the agent's Why. **Save** and **Discard**; **Later** closes it, and it stays in the Inbox.
  - **Access:** "Cursor wants to read Project context", the Mac's line under it, the task. **Allow Once** (prominent, only when offered), **Not Now**, and **Always Allow Cursor to Read Project context** as a link, never the default.
  - A countdown to the request's end ("Answer within 14:59"). **Later** (or Done) closes the sheet without answering.
- **Answering needs the iPhone unlocked:** the answer is refused on the phone while its protected data isn't available ("Unlock your iPhone to answer."). There are no answer buttons on the notification itself.
- **The first answer counts,** on the Mac or a phone: "Answered on your Mac". A panel shown before its memories or the agent's access changed comes back with "This request changed on your Mac. Review it again." An answer that can't reach the Mac says "Mac not reachable" and stays on screen to try again; it's never resent by itself. After a reply that never came, the next look says "Already answered".

## Settings tab
- **Mac:** name, connection type, last contact; "Re-pair", "Unpair this iPhone…".
- **Approvals:** "Approve requests on this iPhone" (the same switch as the Mac's Settings ▸ iPhone, on by default once paired), and why notifications might not come: notifications off for Funes (with **Open Notification Settings**), this iPhone not signed in to iCloud, or the Mac not signed in to iCloud or running a build that can't notify. Requests still show under Waiting for you then.
- **Queue:** N waiting, "Send now", and "Delete queued captures…" (with confirmation).
- **Demo vault:** on or off (only when not paired).
- About and privacy.

## Pairing flow
1. On the Mac: Settings ▸ iPhone ▸ **Pair iPhone…** shows a QR code, valid for 5 minutes.
2. On the iPhone: **Pair with Mac** opens the camera to scan the QR code. Above the camera, "This iPhone's name" is filled in and can be changed: iOS tells apps only "iPhone", so this is where "Sam's iPhone" comes from.
3. The phone creates its keys and connects to the address in the QR code. It tries the LAN address first, then Tailscale, then the tunnel URL. While the request waits, the phone says "Click Allow on “Maya's MacBook Pro”".
4. The Mac shows "iPhone 'Sam's iPhone' wants to pair" with **Allow**, as a second check, plus the device model.
5. Both devices show "Paired". The phone's banner turns to Connected.

If the phone can't reach the Mac during pairing: "Make sure both are on the same Wi-Fi, or set up Tailscale on both." Pairing needs the devices to reach each other once. If Local Network access is off for Funes, it says so and points to Settings ▸ Privacy & Security ▸ Local Network instead.

*Built so far (tasks 5.3 to 5.5):* the four tabs. Capture is as above, without the category and sensitivity chips; on iOS 18–25 the mic button opens the keyboard for its own dictation. Search and the Inbox are as above; Search also has scopes for Archived and Recently Deleted (where a memory can be restored), and a suggestion opens on its own screen with Save, Edit & Save… and Reject. The banner is on Capture, Search and Inbox, as in the States table, plus "Connecting to Maya's MacBook Pro…" while it checks, "Local Network access is off for Funes", and a connected route of Wi-Fi, VPN (the Mac's local address through a VPN such as a Tailscale subnet router), Tailscale or Tunnel. While the Mac can't be reached, Search and the Inbox show why, with **Try Again** and **Why?**; the "Why?" sheet adds what to try, from this iPhone's network and the last check. Settings has pairing, the Mac's name, the connection ("Connected · Wi-Fi", "Mac not reachable", revoked), the last check and its round trip, the signing key's home, the Queue section, and **Unpair This iPhone…**, which asks whether to keep or delete captures that haven't reached the Mac. Debug builds add Spike 1's test capture and protocol checks. Approvals (task 5.6) and demo mode (task 5.7) are as described here.

## Capture surfaces outside the app
- **Share extension:**
  - Takes selected text or a URL, adds an optional note, then saves to the queue.
  - The extension doesn't send anything itself. The App Group queue is drained by the app or by background refresh.
- **App Intent "Remember in Funes"** with a `text` parameter:
  - available in Shortcuts, Siri ("Remember in Funes that…") and the Action button;
  - returns "Saved".
- **Control** (iOS 18+): a Control Center, Lock Screen or Action button control that opens the Capture tab with the keyboard or dictation ready.

## Demo mode (required for App Review)
- About 20 sample memories in a local, read-only store bundled with the app. Edits apply to the session only.
- Captures in demo mode are labelled "Demo" and discarded on exit.
- The App Review notes explain that the app pairs with Funes Vault for Mac, and that the demo shows the full interface.
- *Built (task 5.7):* **Try Demo** sits under the banner on Capture ("No Mac yet? See every screen with sample data. Nothing leaves this iPhone."), and in Search, the Inbox and Settings while the iPhone isn't paired. The demo has 20 active memories (plus one archived and one recently deleted), three Inbox suggestions, and a Share, a Save and an access request under **Waiting for you**, whose panels answer as with a Mac. Every tab's banner is an orange DEMO label with "Demo vault: not your data" and **Leave Demo**; Settings has a Demo section with the Demo Vault switch. A capture goes to the demo's Inbox as a "Demo capture", and its Recent captures row says "Sent to the demo Inbox". Demo mode isn't remembered: the app always launches on the real pairing, and leaving the demo discards its edits and captures. Nothing in it touches the network, the pairing, iCloud or the real capture queue.

## Accessibility
- Dynamic Type everywhere, VoiceOver labels on badges ("Sensitivity: Internal"), and Reduce Motion respected.
- Every action reachable without swipes, using context menus.
