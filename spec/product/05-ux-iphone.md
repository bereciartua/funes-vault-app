# UX: Funes Vault for iPhone (v0.2)

The iPhone app is a **thin client of the Mac's vault**. It captures anywhere, always. It searches, edits and reviews only while the Mac is reachable. It never stores the vault.

## Information architecture

```
Tab bar:  Capture · Search · Inbox · Settings
Extensions: Share extension · App Intent "Remember in Funes" · Control (Control Center / Lock Screen / Action button)
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
- Same cards as on the Mac: source, proposed fields, Apply, Edit & Apply, Reject.
- Swipe right to apply, left to reject. Pull to refresh.

## Settings tab
- **Mac:** name, connection type, last contact; "Re-pair", "Unpair this iPhone…".
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

*Built so far (tasks 5.3 and 5.4):* two tabs, Capture and Settings. Capture is as above, without the category and sensitivity chips; on iOS 18–25 the mic button opens the keyboard for its own dictation. Settings has pairing, the Mac's name, the connection ("Connected · Wi-Fi", "Mac not reachable", revoked), the last check and its round trip, the signing key's home, the Queue section, and **Unpair This iPhone…**, which asks whether to keep or delete captures that haven't reached the Mac. Debug builds add Spike 1's test capture and protocol checks. Search and Inbox come in 5.5.

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

## Accessibility
- Dynamic Type everywhere, VoiceOver labels on badges ("Sensitivity: Internal"), and Reduce Motion respected.
- Every action reachable without swipes, using context menus.
