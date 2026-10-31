# UX: Funes Vault for iPhone (v0.2)

The iPhone app is a **thin client of the Mac's vault**. It captures anywhere, always. It searches, edits and reviews only while the Mac is reachable. It never stores the vault; from v0.4 it keeps only the vault's **counts** (and agent names), for Home and the widgets ([ADR-0025](../architecture/decisions/0025-vault-overview-and-iphone-cache.md)).

## Information architecture

```
Tab bar:  Capture · Search · Inbox · Settings          (v0.2–0.3)
          Home · Search · Inbox · Settings             (v0.4: Home replaces Capture)
Status bar (v0.4): above the tab bar, only when something needs you
Extensions: Share extension · App Intent "Remember in Funes" · Control (Control Center / Lock Screen / Action button) · Widgets (v0.4) · Notification service extension (approvals)
```

The app opens on **Capture** (from v0.4, **Home**, task 7.4, built): the fastest path to the main job.

## States

In v0.2–0.3 each state shows as a banner at the top of Capture, Search and the Inbox. From v0.4 (Phase 7 task 7.1, built) the banner is replaced by the [status bar](#status-bar), which shows nothing while connected; the table's banner column is v0.2–0.3's wording.

| State | Banner (top of every tab) | Capture | Search / Inbox |
|---|---|---|---|
| Not paired | "Pair with your Mac to start" [Pair] | Works, queued locally until pairing | Disabled; offers **Try demo** |
| Connected | "Connected to Maya's MacBook Pro · Wi-Fi" | Sent immediately | Enabled |
| Unreachable | "Mac not reachable · 3 captures waiting" [Why?] | Queued | Disabled, with an explanation |
| Revoked by the Mac | "This iPhone was removed from Funes on your Mac" [Pair again] | Queued captures kept until the user decides | Disabled |
| Demo | "Demo vault: not your data" | Demo only | Demo data |

### Status bar
*v0.4, [Phase 7](../plans/phase-7-home.md) task 7.1.* One bar for the whole app, **above the tab bar**, shown only when something needs you, so no tab spends header space on the connection.
- **Where:** iOS 26's tab view bottom accessory (the glass bar Music uses for its mini player), if it can be hidden when there's nothing to say; otherwise, and on iOS 18–25, a bar of the app's own drawn just above the tab bar.
  - *Built:* the accessory from iOS 26.1, whose `tabViewBottomAccessory(isEnabled:)` turns it off while connected; 26.0's accessory can't be turned off once set, so on iOS 18–26.0 each tab draws the bar itself, a rounded material bar just above the tab bar (a bottom inset, which leaves the large title and the search field alone). The accessory is one line high, so its text is one line; the app's own bar wraps with Dynamic Type. The sheet has the details either way.
- **States** (FunesPhone's `BannerState`):

  | State | Bar | Button | Tapping the bar |
  |---|---|---|---|
  | Connected | none | — | — |
  | Connecting | none for 2 s; then "Connecting to Maya's MacBook Pro…" with a spinner | — | — |
  | Mac not reachable | "Mac not reachable · 3 waiting" (the count only while captures wait) | **Why?** | the status sheet |
  | Local Network off | "Local Network access is off" | **Fix** (the app's page in Settings) | the status sheet |
  | Can't connect | "Can't connect to your Mac" | **Why?** | the status sheet |
  | Not paired | "Pair with your Mac to start" | **Pair** | pairing |
  | Revoked by the Mac | "Removed from Funes on your Mac" | **Pair Again** | the status sheet |
  | Back online | "Back online · 3 captures sent", for 3 s, then the bar goes | — | — |
  | Demo | "DEMO · Demo vault: not your data", always | **Leave Demo** | — |

- **The status sheet** (medium detent): which Mac, when and how it was last reached ("5 minutes ago · Wi-Fi", or "Not since Funes opened"), the queue ("3 captures waiting · Send Now"), the hints of the Why sheet below (with **Open Settings** when Local Network is off; **Pair Again** when removed), and **Try Again**.
- An orange or red icon and words, never colour alone. A state shows only after it has lasted 2 s, so a quick reconnect never flashes the bar; a new count in the same state ("3 waiting" to "4 waiting") shows at once. Connected after Connecting, pairing or Pair Again hides the bar at once; only "Back online" (after the Mac couldn't be reached) waits its 2 s, and counts the captures sent since. It slides in and out (fades with Reduce Motion). The timing is FunesPhone's `StatusBarTimeline`.
- **VoiceOver:** one element read as its text, the button as a custom action, and activating it does what a tap does (on the demo's bar, nothing: Leave Demo is the custom action); each new state is announced once ("Mac not reachable"), not each new count.
- Search and the Inbox keep their full-page explanations while the Mac can't be asked; the bar shows there too, with the queued count. Which Mac the phone is paired with is in Settings and the status sheet.
- While not paired, Capture's first card (from v0.4, Home's card in place of the charts) is **Pair with your Mac to start**, with **Pair with Mac** and **Try Demo** ("No Mac yet? See every screen with sample data. Nothing leaves this iPhone.").

**"Why?" sheet** (from v0.4, the status sheet): "Your vault lives on your Mac. Search and review need the Mac to be awake and reachable on the same Wi-Fi, or through Tailscale. Captures are safe on this iPhone and will be sent automatically."

## Capture tab
- A large text field with the placeholder "What should Funes remember?" and a mic button for dictation (SpeechAnalyzer on iOS 26+, otherwise system dictation).
- **Remember** saves to the local queue instantly (haptic plus a "Saved" toast). It then tries to deliver.
- **Recent captures** list, showing each item's status: "Sent to Mac ✓", "Waiting", or "Blocked: looks like a secret". The phone runs the same secret scanner, so a secret is blocked before it's even queued.
- Optional before sending: category and sensitivity hint chips.

## Home tab
*v0.4, [Phase 7](../plans/phase-7-home.md) task 7.4.* **Home replaces Capture** as the first tab, where the app opens (the Control and "Remember in Funes" open it too). Everything Capture has stays; the vault's pulse joins it, with no memory text or titles.

Top to bottom:
1. **Title:** "Good morning / afternoon / evening" (large title), without a name. *(v0.5 added ", <name>" from the Mac's About You ([ADR-0026](../architecture/decisions/0026-about-you-profile.md)); the large title cut it at most text sizes ("Good afternoon, Mar…"), so the iPhone dropped it after v0.5. The Mac's Home still greets by name, and the pairing record still keeps the name.)* Nothing else in the header (the [status bar](#status-bar) is at the bottom).
2. **Composer:** the Capture tab's field ("What should Funes remember?"), mic and **Remember**: queued instantly, delivered when it can. At rest it's one line with the mic, so the Pulse card starts high on the screen; focused, holding text or dictating, the field grows and **Remember** appears under it.
3. **Waiting for you:** agents' requests, when there are any, above the charts because they have a deadline.
4. **Week tile** (full width): "This week" with its dates ("Oct 25 – 31"), "7 saved · 7 shared" and the last 7 days' in/out chart as on the Mac's Home (in by source above the line, out by agent below, refused dots), a weekday letter under each day. Holding a finger on it, then dragging, puts each day's numbers in place of the week's, with a light haptic per day.
5. **Tiles, two by two:** Memories (total, growth line, "+7 this week") and Rhythm (the last 10 weeks, the streak); Sensitivity (the vault's mix and what was shared, "Vault: 48% Low") and Who reads (the agents shared something in 30 days, most first, with their counts).
6. *(Who reads your vault, the list with when each agent last asked, moved to the Who reads tile's sheet.)*
7. **Recent captures:** the last five with their status; **Show All** for the rest.

- **Taps:** Memories → Search, newest first; Sensitivity → Search filtered by level; Rhythm and the week tile's header → the Pulse sheet, with the chart full width, its legend and the longer ranges (30 days, 12 weeks, 12 months); Who reads → the Who reads sheet.
- **Data:** `overview.get`, on foreground, pull to refresh and after captures are delivered; the answer is cached (ADR-0025).
- **States:**

  | State | Composer | Charts |
  |---|---|---|
  | Connected | as Capture | live |
  | Mac not reachable | as Capture (queued) | the cached snapshot, dimmed, with "As of 10:42" |
  | Not paired | as Capture (queued until pairing) | a **Pair with your Mac** card, with **Try Demo** |
  | Demo | demo | the demo vault's sample counts |
  | New vault | as Capture | "Your pulse starts with your first memories"; Who reads: "Nothing shared in 30 days" (its sheet: "No agent has read your vault yet") |

- *Built (task 7.4; the week tile and the tiles two by two replaced the Pulse card, the three tiles in a row and the Who reads list after v0.5, after the author's use at a large text size: the card took 45% of the first screen and the tiles slid under the tab bar):*
  - **Week tile:** the header row opens the sheet on 7 days (VoiceOver reads it as "This week: 7 saved, 7 shared with 2 agents."); the headline is one line, shrinking rather than wrapping, so scrubbing never moves the chart; a day under the finger reads "Wed, Oct 28 · 53 in · 59 shared · 1 refused" (VoiceOver's step-through and audio graph keep the full breakdown). No switch, no legend, no edge numbers on Home: the sheet has them.
  - **Tiles, two by two:** 22 pt corners, the widgets' look; each row as tall as its taller tile; one column at the accessibility text sizes. Who reads shows the agents shared something in 30 days (up to three, names redacted while locked), each with a bar against the first in the chart's colour for it, and opens a sheet with the rows below.
  - *Up to v0.5:*
  - **Pulse card:** the sentence row opens the sheet (with a chevron); the switch shows 7 or 30 days, both from the 30-day overview, and starts on 30 days. The Out stack names the top three agents by memories shared, then Other. Above the chart: the range's totals ("Last 30 days: 83 in · 194 shared · 2 refused"), or the day under the finger ("Thu, Oct 22 · 2 in (2 iPhone) · 2 shared (Claude Code 2)"). Under it, a legend that names every series. **Scrubbing is press and hold (0.3 s), then drag**, so a swipe that starts on the chart still scrolls Home.
  - **Tiles:** Memories (total, the 12-week growth line, "+23 this week"); Sensitivity (a Vault bar and a Shared bar, coloured by level), which opens a menu of the vault's levels with their counts, each opening Search filtered to that level (Search's filter button changes or clears it); Rhythm (8 weeks, a column per calendar week, and "13-week streak", "No streak yet" or "Too few memories for a rhythm yet").
  - **The sheet:** "Pulse", with 7 days · 30 days · 12 weeks · 12 months (12 weeks and 12 months asked for when shown, then cached), and the 12-week Rhythm grid with "Most on Sundays · 13-week streak". The Rhythm tile opens it on 12 weeks.
  - **Who reads** (now the Who reads sheet, from the 30-day overview whatever the Pulse sheet last showed): agents shared something or asking in 30 days: the name (redacted while locked), "128 memories shared" and how long ago it last asked.
  - **Mac not reachable:** whenever the Mac isn't connected, the charts are faded and greyed, with "As of 10:42" ("As of Oct 21, 10:42 PM" once it isn't today's). A range the cache doesn't have says so in the sheet.
  - The composer is one line (36 pt) at rest. Focusing it, typing, dictating, or the Remember widget and the Control opening it, grow the field to 96 pt (and on as you type) and show **Remember**; closing the keyboard with the field empty folds it back. *(Was 96 pt with **Remember** always shown, about half the first screen, until the author's first days of use.)*
  - **Closing the keyboard:** Return adds a line, so the keyboard has a **Done** button above it, scrolling Home pulls it down (interactively), and tapping anywhere outside the field closes it (taps on tiles, cards and Waiting for you still work). Each keeps the text; none stops dictation. The memory edit sheet (Edit, and the Inbox's Edit & Save) and the share extension's note have the same **Done**.
  - **The pulse's scales:** as on the Mac, each half has its own: the line in the middle, the busiest In bucket reaching the top and the busiest Out bucket the bottom (above the refused dots). A faint number at each edge with a faint gridline gives that half's peak; a half with nothing stays empty and unlabelled. The words above the chart, scrubbing and VoiceOver give the real counts. The Pulse widget has the same scales without the edge numbers (its line gives the week's totals).

## Search tab
- A search field. Results come from the Mac, showing the title, a two-line snippet, category chips and a sensitivity badge. From v0.6 the snippet is the passage that matches the search, with the matches the Mac marks (`snippetMatches`) highlighted (FR-V-17).
- **Search answers** (v0.6, FR-iOS-13, [ADR-0028](../architecture/decisions/0028-search-answers.md)): while the Mac reports them on (`searchAnswers` in `status.get`) and **Show Ask in Search** is on, an **✦ Ask Funes** pill sits under the search field once results load (Active scope, a non-empty search).
  - Tapping it shows the card as the list's first section: "Reading 10 results…" with **Cancel**, then the answer as on the Mac (claims with numbers and quotes, the locality badge as "Claude · Cloud" or "On your Mac", the footer, **Clear**). The pill hides while the card shows.
  - When the Mac answers automatically (`searchAnswers.trigger` in `status.get`: questions or every search), the pill turns into the card on its own after the same pause as on the Mac, once for each search ([memory processing §10.6](../domain/memory-processing.md#106-limits-and-automatic-answers)); never while Show Ask in Search is off.
  - A number opens the memory detail scrolled to the quoted sentence, highlighted (the phone finds it with `QuoteLocator`; an edited memory opens without the highlight).
  - Messages: the Mac's no-answer and failure texts; "Search answers are off on your Mac." (`answers_off`, the pill then hides); a call that can't reach the Mac is the usual unreachable state, and a slow model is never shown as one.
  - The footer's withheld line says "1 memory wasn't read: it's above your Mac's cloud limit" (the phone isn't told the limit's name), or for a model on the Mac or a local server "1 memory wasn't read: it looks like it holds a secret".
  - **Cancel** or changing the search or scope clears the card and stops waiting; the Mac's work ends at its result, its deadline or the phone's next Ask. Opening a memory (a result or a number) or another tab keeps the card, and an answer still on its way lands there.
  - The last answer stays in the app's memory (never on disk), so going back to its search brings it back without asking again, as long as the same memories come back unedited, the Mac answers with the same model and Ask shows. **Clear**, a newer answer, unpairing or answers turned off drop it.
- **Memory detail:**
  - full text, kind, categories, sensitivity, expiry and provenance;
  - **Edit**, **Archive** and **Delete**.
  - Edits are sent to the Mac and confirmed. A failed save shows an error, and the text is kept until it saves.
- Nothing is cached after leaving the screen, beyond in-memory state. (The one exception, from v0.4, is the overview's counts for Home and the widgets: no memory text or titles; [ADR-0025](../architecture/decisions/0025-vault-overview-and-iphone-cache.md).)

## Inbox tab
- Same cards as on the Mac: source, proposed fields, Save, Edit & Save, Reject (the [glossary](06-glossary.md)'s words).
- Swipe right to save, left to reject. Pull to refresh.
- **From v0.3** (Phase 6): pieces of a split input are ordinary suggestions, shown one per row with "Part of: <source>". Tidy-up cards (merge, split, conflict) and anything else the phone doesn't know yet show as one row, "N to review on your Mac", until a later iPhone update adds them. Saving a piece applies its own action (new, update, already saved, removes), never Keep both for everything.
- **Processing** (memory processing §5.2): a suggestion the Mac is still splitting is a greyed **Processing…** row that can't be saved or edited (no Save swipe or button; "Your Mac is still splitting this into separate memories. It can be saved once that's done."); **Reject** works and cancels it. Pull to refresh shows the result. A split that failed shows **Couldn't split** with **Try Again** (also the leading swipe) and **Keep as One**, after which it's an ordinary suggestion. A Save approval for an agent's suggestion only arrives once processing is done, one per piece.

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
- **Mac:** name, connection type, the version of Funes on the Mac ("Funes on the Mac"), last contact; "Re-pair", "Unpair this iPhone…".
- **Approvals:** "Approve requests on this iPhone" (the same switch as the Mac's Settings ▸ iPhone, on by default once paired), and why notifications might not come: notifications off for Funes (with **Open Notification Settings**), this iPhone not signed in to iCloud, or the Mac not signed in to iCloud or running a build that can't notify. Requests still show under Waiting for you then.
- **Queue:** N waiting, "Send now", and "Delete queued captures…" (with confirmation).
- **Search answers** (v0.6, while paired): **Show Ask in Search** (on by default, this iPhone only), "Answered by <engine>" and "Answers: When you ask · Automatically for questions · Automatically for every search" from the Mac, with the footer "Your Mac reads the top results and asks <engine>. Change the model, and when searches are answered, on your Mac in Settings ▸ AI ▸ Features ▸ Search answers. With Show Ask off, nothing is asked from this iPhone." When the Mac has them off: "Search answers are off on your Mac." and no switch.
- **Demo vault:** on or off (only when not paired).
- **Funes for iPhone:** this app's version and build ("0.5.0 (11)"), paired or not, so it isn't mistaken for the Mac's.
- About and privacy.

## Pairing flow
1. On the Mac: Settings ▸ iPhone ▸ **Pair iPhone…** shows a QR code, valid for 5 minutes.
2. On the iPhone: **Pair with Mac** opens the camera to scan the QR code. Above the camera, "This iPhone's name" is filled in and can be changed: iOS tells apps only "iPhone", so this is where "Sam's iPhone" comes from.
3. The phone creates its keys and connects to the address in the QR code. It tries the LAN address first, then Tailscale, then the tunnel URL. While the request waits, the phone says "Click Allow on “Maya's MacBook Pro”".
4. The Mac shows "iPhone 'Sam's iPhone' wants to pair" with **Allow**, as a second check, plus the device model.
5. Both devices show "Paired". The phone's banner turns to Connected.

If the phone can't reach the Mac during pairing: "Make sure both are on the same Wi-Fi, or set up Tailscale on both." Pairing needs the devices to reach each other once. If Local Network access is off for Funes, it says so and points to Settings ▸ Privacy & Security ▸ Local Network instead.

*Built so far (tasks 5.3 to 5.5):* the four tabs. Capture is as above, without the category and sensitivity chips; on iOS 18–25 the mic button opens the keyboard for its own dictation. Search and the Inbox are as above; Search also has scopes for Archived and Recently Deleted (where a memory can be restored), and a suggestion opens on its own screen with Save, Edit & Save… and Reject. Until task 7.1 the banner was on Capture, Search and Inbox, as in the States table, plus "Connecting to Maya's MacBook Pro…" while it checks, "Local Network access is off for Funes", and a connected route of Wi-Fi, VPN (the Mac's local address through a VPN such as a Tailscale subnet router), Tailscale or Tunnel. While the Mac can't be reached, Search and the Inbox show why, with **Try Again** and **Why?**; the "Why?" sheet (from 7.1, the status sheet) adds what to try, from this iPhone's network and the last check. Settings has pairing, the Mac's name, the connection ("Connected · Wi-Fi", "Mac not reachable", revoked), the last check and its round trip, the signing key's home, the Queue section, and **Unpair This iPhone…**, which asks whether to keep or delete captures that haven't reached the Mac. Debug builds add Spike 1's test capture and protocol checks. Approvals (task 5.6) and demo mode (task 5.7) are as described here.

## Capture surfaces outside the app
- **Share extension:**
  - Takes selected text or a URL, adds an optional note, then saves to the queue.
  - The extension doesn't send anything itself. The App Group queue is drained by the app or by background refresh.
- **App Intent "Remember in Funes"** with a `text` parameter:
  - available in Shortcuts, Siri ("Remember in Funes that…") and the Action button;
  - returns "Saved".
- **Control** (iOS 18+): a Control Center, Lock Screen or Action button control that opens the Capture tab (from v0.4, Home's composer) with the keyboard or dictation ready.

## Widgets
*v0.4, [Phase 7](../plans/phase-7-home.md) task 7.5.* Home's cards as Home Screen widgets (and StandBy), in the Intents extension next to the Control. They read the cached overview (ADR-0025) and never call the Mac.

| Widget | Sizes | Shows | Tap |
|---|---|---|---|
| **Pulse** | medium | "7 saved · 7 shared · 1 refused" this week, and the 14-day in/out chart | Home |
| **Remember** | small | "What should Funes remember?", **Remember** and **🎙** | the buttons open Home's composer, typing or dictating |
| **Rhythm** | small (6 weeks), medium (12 weeks and the streak) | the grid of days | Home |

- **Later** (not in v0.4's first set): Memories (small), a large "Funes" widget (Home in miniature), Pulse in large, and Lock Screen widgets (counts only).
- **Freshness:** the app rewrites the cache and reloads the widgets on foreground, pull to refresh, after captures are delivered and in its background refresh when the Mac answers. A midnight timeline entry moves the days along. "as of 10:42" once the snapshot is over an hour old; dimmed after a day.
- **States:** Not paired: "Pair with your Mac" in place of the numbers (Remember still works, captures queue); Demo: demo numbers with a **DEMO** label.
- **Privacy:** no memory text or titles; agent names are `.privacySensitive()`, so iOS redacts them while the phone is locked.
- *Built (task 7.5):* Pulse is headed "Funes · this week", with "Shared with Claude Code, Cursor, Codex" under its chart. Rhythm medium says the streak, the busiest weekday and "41 new in 12 weeks", in Home's words ("13-week streak", "Most on Sundays"). Without counts yet, Pulse and Rhythm say "Your pulse shows here · Open Funes once your Mac is near"; the gallery shows the demo's counts. The demo is labelled **DEMO** and never says "as of". 🎙 opens the composer dictating where the app has its own dictation (iOS 26), else with the field focused, as Home's mic does.

## Demo mode (required for App Review)
- About 20 sample memories in a local, read-only store bundled with the app. Edits apply to the session only.
- Captures in demo mode are labelled "Demo" and discarded on exit.
- The App Review notes explain that the app pairs with Funes Vault for Mac, and that the demo shows the full interface.
- *Built (task 5.7):* **Try Demo** sits under the banner on Capture ("No Mac yet? See every screen with sample data. Nothing leaves this iPhone."), and in Search, the Inbox and Settings while the iPhone isn't paired. The demo has 20 active memories (plus one archived and one recently deleted), three Inbox suggestions, and a Share, a Save and an access request under **Waiting for you**, whose panels answer as with a Mac. Every tab's banner is an orange DEMO label with "Demo vault: not your data" and **Leave Demo**; Settings has a Demo section with the Demo Vault switch. A capture goes to the demo's Inbox as a "Demo capture", and its Recent captures row says "Sent to the demo Inbox". Demo mode isn't remembered: the app always launches on the real pairing, and leaving the demo discards its edits and captures. Nothing in it touches the network, the pairing, iCloud or the real capture queue.

- *From v0.4 (task 7.1, built):* the DEMO label is the [status bar](#status-bar) (with Leave Demo), from the first frame and on every tab, and Try Demo is on Capture's pairing card (from task 7.4, Home's, in place of the charts) and in Search, the Inbox and Settings while the iPhone isn't paired. Home's charts show the demo's 12 weeks of sample counts.

- *From v0.6:* the demo's Search has the Ask pill. A few sample questions get their sample results and canned answers from `DemoVault`, citing its memories ("When does my lease renew?", "What's my next garden milestone?", "How often do I run?"): the demo's search matches whole phrases only, so each question maps to its results. Any other search gets "In the demo, try: When does my lease renew?" (the demo answers it as `model_unavailable` with the reason `demo_hint`, which only the phone's demo uses). The demo's engine is "Demo", on device. No network.

## Accessibility
- Dynamic Type everywhere, VoiceOver labels on badges ("Sensitivity: Internal"), and Reduce Motion respected.
- Every action reachable without swipes, using context menus.
