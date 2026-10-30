# Changelog

Notable changes to Funes Vault, newest first, in the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. Versions follow `MARKETING_VERSION` in the Xcode project. Release notes come from this file.

## [Unreleased]

### Added

- **Search answers: ask, and get the fact with its source.** Turn on **Settings ▸ AI Models ▸ Search answers** (off by default) and press **⌘Return** in the Vault's search, or click **Ask Funes** above the results: the model you chose (the one for New memories unless you pick another) reads the top 10 results and answers in up to three short claims, each with the sentence it quotes and a number that opens that memory with the sentence highlighted. Claims it can't quote from your memories are left out, and it's asked to show both sides when memories disagree. The results below don't move. To skip the click, set **Answer** to **Automatically for questions** (a search ending in "?" or starting with a question word, in English or Spanish) or **Automatically for every search**: the answer starts on its own after a short pause, once for each search, and each one sent to a cloud model counts toward today's cloud requests. The iPhone's Search has the same **Ask Funes**, answered by your Mac (automatically too, when the Mac is set to), and **Settings ▸ Search answers** to hide it. Nothing is kept: the answer stays until you change the search, and Activity records only that you asked. On Funes's synthetic test questions, 96–100% of the claims Claude Haiku, GPT-5.6-Terra and GPT-6-Luna gave were correct, in about 4 seconds; Apple's on-device model is too slow and inaccurate for this and is labelled so.

- **Search shows the sentence that matches.** In the Vault and in the iPhone's Search, a result's preview is now the part of the memory that matches your search, with your search's words in bold, instead of the memory's first line. For "What's my title at Chatham?" you see "…My title at Chatham is Senior Analyst…" even when that sentence is deep in a long memory. Without a search, or when only the meaning matches, the preview is the memory's start as before. Search in a large vault is also faster.

- **Tidy Up on one memory.** A memory's detail (and the Vault list's right-click menu) now has **Tidy Up**, which checks just that memory against itself and up to 5 related memories with your tidy-up model, instead of the whole vault. What it finds waits in the Inbox (**Show in Inbox** takes you to it); nothing is applied automatically, and suggestions you dismissed before can come back. It doesn't count as the day's tidy-up.

- **iPhone: the app's own version in Settings.** A new **Funes for iPhone** section at the bottom of Settings shows the iPhone app's version and build ("0.5.0 (11)"), paired or not. The Mac section's version row is now called **Funes on the Mac**, since it's the Mac's version.

### Fixed

- **iPhone: searching no longer says your Mac isn't reachable.** Typing in Search often showed **Mac not reachable** until you tapped Try Again. Each new letter cancels the search still on its way to the Mac, and the app took that cancelled search for the Mac not answering. It also forgot the Mac's address, so the next search had to find the Mac again. A cancelled search is now just dropped, and while new results are on their way a spinner shows at the top left over the previous results. Leaving the Inbox or a memory before it loads no longer reports the Mac unreachable either.

- **The tidy-up no longer gives up on one slow answer.** A tidy-up through Codex or Claude on your plan could stop partway with "stopped early: the model didn't answer", because each call had only 20 seconds. Calls through those apps now get 60 seconds, a call that fails is tried once more, and if it fails again the tidy-up skips those few memories and goes on, stopping only after three failures in a row. When it does stop early, the Inbox says how many memories are left and why ("2 left: the model took too long to answer") and offers **Try Again**, or **AI Models…** when the model's sign-in or setup is the problem.

- **A correction now updates the memory's title too.** When a new capture changed a saved memory, Funes kept the old title and could fold it into the new text, leaving "Likes the color blue" over a text about orange. Corrections now come with a title that matches the new text, and the tidy-up retitles a memory whose title no longer matches its own text.

## [0.5.0] - 2026-10-27

### Fixed

- **Suggestions answered on the iPhone no longer wait on the Mac.** Saving or rejecting a suggestion in the iPhone's Inbox (or the Mac's) now closes its **Save this memory?** panel on the Mac at once. Before, every one stayed queued behind "+N more" until answered again.
- **Acting on a new card while Funes was splitting it no longer fails.** Saving, editing or approving a capture, an agent's suggestion or an imported item mid-split could end in an error when the split replaced the card. Such a card now shows **Processing…** until the split is done (see **Split into separate memories** below).
- **Split memories keep their context.** When Funes splits a long memory (in the daily tidy-up) or a new suggestion into separate memories, each piece now says who or what it's about and, for something that happened, when: "The Staff Data Engineer role at Verdant Grid I interviewed for in October 2026 is fully remote", not "The role is fully remote". Pieces with no lasting value (asking what a word means, how to send a file) are left out. The model now gets the memory's title and date as well as its text. On Funes's test set, 81% of pieces made sense on their own to an agent that saw only them, up from 43%.
  - Tidy-up splits proposed before this update are proposed again at the next run, and ones you rejected are offered once more. A split you have open isn't replaced under you.

- **Inbox: every suggestion applies as what it says.** Applying a suggestion to archive a memory used to save a new memory instead; it now archives that memory. A correction replaces the memory when you click Replace or Save on the iPhone (Keep Both is only offered on the Mac, for corrections). Selecting several suggestions and clicking Apply applies each as its own kind.
- **No more silent overwrites.** A correction whose memory was edited, archived or deleted after it was suggested says "Changed since this was suggested" instead of overwriting the newer text; **Review Again** shows the memory as it is now. The Mac's memory editor also refuses to save over a change made meanwhile (from the iPhone, for example) and offers to reload.

### Added

- **See what a change did.** Selecting an automatic change in Activity (applied automatically, a tidy-up merge, update, split or archive, or an undo of one) now shows each memory it touched: **New**, **Changed**, **Archived** or **Restored**, the old text struck through above the new, and kind, categories, sensitivity and expiry as "Low → Internal". A tidy-up run lists its changes and links to the Inbox for the suggestions it left. Funes keeps these details for 30 days, the same as Undo.
  - **Earlier versions.** Every other change to a memory now keeps the version it replaced: your edits on the Mac and the iPhone, agents' writes, suggestions you apply from the Inbox, archiving and restoring. Activity and History show those as before → after too, for 90 days (at most 50 versions a memory). They stay on this Mac: never shared with agents, exported or sent to your iPhone. **Forget Earlier Versions…** in a memory's History deletes its earlier versions, and Settings ▸ Data ▸ **Keep earlier versions for 90 days** turns them off and deletes them. The vault gets one new table when it updates.
  - **A memory's History** opens the same details in place: click the chevron on a change's row. A merge's or split's row links to the other memory, **Show in Activity** selects that row in Activity, and **Show All in Activity** opens everything about the memory. Activity's memory view now includes the changes Funes made to it.
  - **Inbox ▸ Applied automatically:** each change opens to its before and after too.
  - The detail pane is now as tall as its content, so short rows leave more room for the list, and **×** closes it.
- **Later for all.** When several **Save this memory?** panels are waiting, **Later for all N suggestions** closes them in one click. They stay in the Inbox; requests an agent is waiting on keep their panels.
- **About You.** A new first pane in Settings for what Funes and your agents call you: your name, what to call you, pronouns, languages, location, time zone and occupation, all optional. The setup questions now start with "What should Funes call you?".
  - **Home greets you by name** on the Mac and the iPhone: "Good afternoon, Martin." With no name set it's "Good afternoon.", never your macOS account name (which may be a username like "mib"); About You offers that name as a suggestion only when it looks like a person's.
  - **Agents can know your name.** Each agent's Access tab has an About you section with a checkbox per field; a new agent, and every agent you already have, shares your name and nothing else. The fields you tick go with every answer to that agent's memory requests, without asking: also while a request waits for you, and when no memory matched, so "What's my name?" just works. Paused or expired agents, and agents that can't read, get none. Changing an agent's fields is an access change: its waiting requests ask again.
  - The Share panel says what the agent already has ("Claude Code also has your name and pronouns, as set in its Access."), Activity shows "Also sent: name, pronouns" (names, never values) and "Edited About you", and About You shows how many agents get each field. The secret check runs on every field. Exports include the profile; restoring one fills an empty profile only. The vault gets two small tables when it updates.
- **iPhone: Home Screen widgets.** Three of Home's cards, from the counts your Mac last sent (the widgets never contact the Mac themselves):
  - **Pulse** (medium): "7 saved · 7 shared · 1 refused" this week, and the last 14 days in and out, with the refused dots.
  - **Remember** (small): "What should Funes remember?", with **Remember**, which opens Home ready to type, and 🎙, ready to dictate. It works before pairing too: captures wait on the iPhone.
  - **Rhythm** (small, the last 6 weeks; medium, 12 weeks with your streak and busiest day).
  - Tapping Pulse or Rhythm opens Home. The days move along at midnight; once the counts are over an hour old the widget says "as of 10:42", and after a day it fades them. The iPhone refreshes them whenever it hears from your Mac, including in its background refresh. Agent names are hidden while the iPhone is locked; the demo's counts are labelled **DEMO**; an iPhone that isn't paired says "Pair with your Mac".
- **iPhone: Home.** The app now opens on Home, which takes Capture's place as the first tab and keeps everything Capture had: the box to remember something (typed or dictated), **Waiting for you**, and Recent captures (the last five, then **Show All**). Below them, your vault at a glance, counts only, never a memory's text:
  - **Pulse:** "This week: 23 saved, 44 shared with 3 agents." and a chart of the last 7 or 30 days, new memories by where they came from above the line, memories shared with each agent below it, and a red dot for refused requests. Hold a finger on the chart and slide it to read each day's numbers. Tap the sentence for 12 weeks and 12 months.
  - **Memories** (the total, its growth over 12 weeks and what's new this week) opens Search, newest first; **Sensitivity** (how sensitive the vault is, and what was shared) searches by level; **Rhythm** (the last 8 weeks, day by day, and your streak) opens the longer view.
  - **Who reads your vault:** your top three agents, how many memories each was shared in 30 days, and when each last asked.
  - While your Mac is away, Home shows the last counts it sent, faded, with "As of 10:42". While the iPhone isn't paired, the pairing card with **Try Demo** takes the charts' place; the demo has sample counts.
  - Search has a sensitivity filter. The Control opens Home, ready to type or dictate.
- **Home on the Mac.** The window now opens on Home, at the top of the sidebar (⌘1; Vault, Inbox, Activity, Agents and Remote Access move to ⌘2–⌘6), and so does **Open Funes Vault**. The setup checklist moved there from the Vault.
  - Type a memory and press Return: it goes to the Inbox exactly as from the ⌥⌘M box, with the same "Saved to Inbox", Cloud label and secret check. Shift-Return adds a line; **⌘Return** opens the Vault searching for what you typed.
  - A microphone in Home and in the ⌥⌘M box dictates into the field, on your Mac (macOS 26 and later). It asks for microphone and speech recognition access the first time. On macOS 15 there's no microphone button; the system's own dictation still works there.
  - The vault's pulse: this week in a sentence ("This week: 9 saved, 23 shared with 3 agents, 2 refused."), then each day's new memories by where they came from (you, your iPhone, agents, imports, the tidy-up) above a line, and the memories shared with each agent below it, with a red dot for refused requests. 7 days, 30 days, 12 weeks or 12 months, remembered. Hover a day for its numbers; click it to see that day in Activity, or click a red dot for that day's Problems.
  - Cards for your memories and their growth over 12 weeks, the vault's sensitivity next to what was shared, a 12-week grid of when memories came in ("Most on Sundays · 3-week streak"), and the agents that read your vault most. Each opens the Vault or Activity at the right place. Under them, how many suggestions wait in the Inbox and when the last tidy-up ran.
  - Home shows counts only, never a memory's text or title. VoiceOver reads the chart's totals and each day, and offers it as an audio graph; with Reduce Motion it doesn't animate.
- **The vault's counts on the iPhone,** the groundwork for Home and widgets: how many memories came in and went out to each agent, the totals by sensitivity, category and kind, and each agent's name and last request. The iPhone asks your Mac when it opens or comes to the front and keeps the last answer, never a memory's text or title, so Home and the widgets will have something to show while the Mac is away; unpairing, removing the iPhone on the Mac or leaving the demo deletes it ([PRIVACY.md](PRIVACY.md#funes-vault-for-iphone)). Each read shows in the Mac's Activity as "Read the vault's counts". The vault gets five indexes when it updates, which keep these counts under 50 ms on a 10,000-memory vault.
- **A provider's embedding model for search** (Settings ▸ AI Models ▸ Embeddings, none by default). Next to the built-in model, Funes can use Qwen3-Embedding in Ollama or LM Studio, or OpenAI's text-embedding-3-small or -large, which find more for requests that come without keywords and for other languages (on Funes's tests, Spanish requests to English memories: from 31% to 62% of the right memories in the top 5 with Qwen3).
  - Before it starts, Funes says how many memories and roughly how many tokens it will send. Search keeps using the built-in model until every memory is done, and you can cancel any time; cancelling, or **Stop Using**, deletes the provider's vectors.
  - Memories above your cloud limit are never sent to a cloud provider: they keep the built-in model, so they're still found, and their page says "Searched on this Mac only". A local server embeds every memory.
  - With a cloud model, **Embed agent requests with the cloud model** (on by default) decides whether agents' requests go to it too; the line below says what is sent where. If the provider is down, search uses the built-in model.
  - A provider's own settings now call their model field **Chat model** (for New memories and the tidy-up), and say so when an embedding model is typed there, where Test Connection used to fail with an unexplained error (400).
  - Other embedding models work too: Funes keeps their 10 closest matches until you **Calibrate…** them with its made-up benchmark. What the provider receives is in [PRIVACY.md](PRIVACY.md#search-embeddings).
- **Daily tidy-up** (Settings ▸ AI Models ▸ Daily tidy-up, off by default). Once a day at the time you pick, or when you click **Tidy Up Now**, Funes compares memories that changed with related ones and proposes what to clean up, in a new **Tidy-up** section of the Inbox:
  - **archive** a copy or an out-of-date memory ("Keeps *the other one*"), **update** a memory with a newer fact, **merge** memories that say parts of one thing (showing what each kept), **split** a memory that holds several things, and **conflicts**, which ask you which is true: **Keep This**, **Both Are True** or **Edit…**.
  - Exact copies and expired memories are found on your Mac without any model. Everything else needs a local server or a cloud model, the one chosen for New memories unless you pick another; Apple's on-device model isn't used for this. The first run on a large vault works through it over a few days, newest changes first, and Settings shows an estimate of the requests before it starts.
  - Funes never merges memories with different categories or sensitivity, never makes a memory easier for an agent to read, and refuses a merge that would drop a "not", "never" or "except". Proposals you reject, and conflicts you answer **Both Are True**, aren't asked again while those memories stay the same; a proposal whose memories change before you decide is dropped and looked at again.
  - **Apply changes automatically** now covers the tidy-up, per model, where it was accurate enough on Funes's test set: **Duplicates only** with GPT-5.6-Terra, Claude Haiku 5.5 and Claude Opus 5.5, **Everything except conflicts** with Haiku and Opus. Conflicts always wait for you, and nothing is changed on the strength of what an agent wrote, except archiving an exact copy of it. Each change is listed in **Applied automatically** with **Undo** for 30 days; undoing a merge or split brings the originals back.
  - When a run finds something, a notification says how many changes it applied and how many wait for you, with no memory text. The iPhone shows tidy-up cards as "Review on your Mac".
  - What the provider receives is in [PRIVACY.md](PRIVACY.md#ai-models).
- **Use your Claude or ChatGPT plan** (Settings ▸ AI Models ▸ Use your subscription). If you have Claude Code or Codex installed and signed in, Funes can use it for New memories instead of an API key. Settings shows whether each is found and signed in, and the command to sign in if not; Test Connection sends one made-up note. Funes never sees your sign-in, runs each request with no tools, plugins of your own, MCP servers or hooks, and stops a run that tries to use one. ChatGPT (Codex) is off until you turn on "Use Codex even though it can read files on this Mac": Codex can't have its file-reading commands switched off. Requests count toward your plan's limits and your account's training setting applies ([PRIVACY.md](PRIVACY.md#ai-models)).
- **Split into separate memories** (Settings ▸ AI Models ▸ New memories, off by default). With a local server or a cloud model chosen, captures, your answers, agents' suggestions and imports are split into one suggestion per claim, each linked to what your vault already holds.
  - The Inbox shows them on one card: "From ChatGPT · 12 pieces", the original text, and each piece marked **New**, **Updates** *a memory*, **Already saved** or **Removes** *a memory*, with its own Apply and Reject. **Apply All** applies each as it says; **Keep as One** puts the original back while nothing is decided.
  - Until it's split, a new card says **Processing…** and why it's waiting ("Splitting with Claude…", "2 ahead of it", "Waiting: today's model limit reached"). It can't be applied or edited yet, on the Mac or the iPhone, and Apply on a selection skips it; you can still reject it, which cancels the split. When the split is done, the result takes its place.
  - If the split fails (the provider is down, it takes too long, its answer is unusable), the card says **Couldn't split**, with **Try Again** and **Keep as One**.
  - An agent's **Save this memory?** panel waits for the split, then shows one panel per piece. The agent gets its answer at once, as before.
  - A piece an agent couldn't save itself (another category, or more sensitive than its limit) says **Outside** *agent*'s **scope**, and Apply All leaves it for you. A memory an agent saved directly is offered as **Split This Memory**, and is made more sensitive at once if a piece is.
  - Imports show how many requests splitting takes and what's left of today's cloud requests, and offer **Import Without Splitting**. At the daily limit, agents' input and imports wait for the next day.
  - Apple's on-device model doesn't split: it keeps proposing fields only. Nothing is applied automatically yet: no model was accurate enough on Funes's test set, so **Apply changes automatically** stays Off. The **Applied automatically** list in the Inbox, with Undo, is ready for when it is.
  - What goes to the provider with splitting on is in [PRIVACY.md](PRIVACY.md#ai-models).
- **More choice for the cloud limit.** Settings ▸ AI Models ▸ Cloud limit now goes from Public to Restricted, **Everything, including Secret**, or **Nothing**. Choosing a level above Internal asks you to confirm first. Text that looks like a secret is never sent, whatever the limit.
- **Cloud requests per day.** A daily limit on requests to cloud providers, 300 by default, set in Settings ▸ AI Models, which shows today's count. Agents' input may use at most 40% of it. At the limit, new captures are classified on this Mac until the next day, and Funes says so once.

### Changed

- **The pulse chart gives each half its own scale,** on the Mac's Home, the iPhone's Home and its Pulse widget. The line now sits in the middle, new memories fill the top half and memories shared fill the bottom, so a quiet week of saving is no longer squashed flat by a busy week of sharing. A small number at the top and bottom edge says what each half's tallest bar stands for ("3 in", "22 out" on the Mac); hovering, scrubbing and VoiceOver still give the real counts.
- **iPhone: Home's box to remember something is one line until you use it.** Tap it and it grows, with **Remember** under it; close the keyboard with nothing typed and it folds back. The Pulse card now starts near the top of the screen.
- **iPhone: swiping on the pulse chart scrolls Home.** A swipe that started on the chart used to be caught by it. To read a day's numbers, hold your finger on the chart for a moment, then slide it.
- **iPhone: the keyboard closes without saving.** On Home, tap **Done** above the keyboard, scroll, or tap anywhere outside the box; what you typed stays. The memory edit sheet and the share extension's note have **Done** too.
- **iPhone: a status bar instead of the connection banner.** Capture, Search and the Inbox no longer start with a banner. While your Mac is connected, nothing shows; when something needs you, one bar appears just above the tabs: "Mac not reachable · 3 waiting" (**Why?**), "Local Network access is off" (**Fix** opens the app's page in Settings), "Can't connect to your Mac", "Pair with your Mac to start" (**Pair**), "Removed from Funes on your Mac" (**Pair Again**), and "Back online · 3 captures sent" for a few seconds once the Mac is back.
  - A state shows only after it has lasted 2 seconds, so a quick reconnect never flashes the bar.
  - Tapping the bar opens a status sheet: which Mac, when and how it was last reached, the captures waiting with **Send Now**, what to try, and **Try Again**.
  - On iOS 26.1 and later it's the glass bar above the tab bar (where Music shows what's playing); earlier versions get a bar of the app's own in the same place.
  - In the demo, the orange DEMO label and **Leave Demo** are in the bar. **Try Demo** is on Capture's new pairing card while the iPhone isn't paired.
  - VoiceOver reads the bar as one element, with its button as an action, and announces each new state once.
- **Settings ▸ AI Models ▸ New memories** replaces Classification. The switch for proposing a title, kind and categories moved here from Settings ▸ Capture, next to two settings for later versions: splitting what arrives into separate memories, and applying changes automatically (Off for now).
- **Exports keep more.** Restoring a Funes export as memories keeps archived memories archived and keeps the links between memories that were split or merged.
- **iPhone captures get proposed fields too.** They're classified by the model chosen in Settings ▸ AI Models, like captures on the Mac, instead of only by Funes's built-in rules. Captures still being classified when Funes quits are finished at the next launch.
- The vault moves to a new format for v0.3's memory processing. Funes backs it up first (`Backups/pre-v4_memory_processing-….sqlite`).

## [0.2.0] - 2026-10-22

Funes Vault now has an iPhone app, Funes Vault for iPhone on the App Store. It pairs with this Mac to capture, search, edit, review the Inbox and approve agents' requests. Your vault stays on your Mac.

### Added

- **iPhone access on the Mac.**
  - A new Settings ▸ iPhone turns on iPhone access (off by default) and chooses how the phone reaches this Mac: Same Wi-Fi, Tailscale or a public tunnel.
  - **Pair iPhone…** shows a QR code for 5 minutes, then asks "“Sam's iPhone” wants to pair" with Allow or Deny. Paired iPhones are listed with when they were last seen, and **Remove…** cuts one off.
  - Everything the phone sends is end-to-end encrypted to this Mac. A paired iPhone acts as you, and what it does shows in Activity under its name.
  - macOS asks for Local Network access the first time iPhone access is on.
  - With Tailscale on, the iPhone reaches this Mac through Tailscale from anywhere, not only on the same Wi-Fi.
- **Funes Vault for iPhone: pairing.**
  - **Pair with Mac** scans the code from Settings ▸ iPhone ▸ Pair iPhone…, then waits while you click Allow on the Mac. Name the iPhone before scanning: iOS only tells apps "iPhone".
  - It then shows whether your Mac is reachable and how: "Connected · Wi-Fi", "Connected · Tailscale", "Connected · VPN" (your Mac's local address through a VPN such as a Tailscale subnet router), or "Mac not reachable". It also says so when Local Network access is off for Funes. It checks again whenever the app comes to the front or the network changes.
  - The iPhone's signing key is made in the Secure Enclave and never leaves it; the keys and the pairing stay on this iPhone only.
  - **Unpair This iPhone…** tells the Mac and forgets the keys.
- **Capture on the iPhone.** The app opens on Capture.
  - Type, or tap the mic to dictate (on iOS 26 and later, turned into text on the iPhone; earlier versions use the keyboard's dictation). **Remember** saves at once, even with no network, and sends it to your Mac when it's reachable.
  - Text that looks like a password, key or card number is blocked before it's saved, with the same rules as the Mac.
  - Recent captures show "Sent to Mac", "Waiting" or why your Mac didn't accept one. "Mac not reachable · 3 captures waiting" says what's still on the iPhone.
  - Captures wait on the iPhone, up to 1,000, and leave it only once your Mac has them, each exactly once. Funes sends them when the app opens or comes to the front, when the network changes, right after a capture, and in the background now and then; while your Mac is away it waits longer between tries, up to 30 minutes.
  - **Share to Funes** from any app saves the selected text or link with an optional note. **Remember in Funes** works in Shortcuts, with Siri and on the Action button. A **Capture in Funes** control for Control Center, the Lock Screen and the Action button opens Capture ready to type.
  - Settings shows how many are waiting, with **Send Now** and **Delete Queued Captures…**. Unpairing asks whether to keep or delete captures that haven't reached your Mac.
- **Search, edit and review on the iPhone.** The Search and Inbox tabs read your vault on your Mac while it's reachable.
  - **Search** asks your Mac and lists each memory's title, two lines of its text, its categories and its sensitivity. Scopes show Archived and Recently Deleted memories too.
  - A memory opens with its full text, kind, categories, sensitivity, expiry, how often it was shared and its history. **Edit**, **Archive**, **Restore** and **Delete…** save on your Mac. If the memory changed on your Mac meanwhile, the iPhone asks "Changed on your Mac, reload?" instead of overwriting it. A save that fails says why and keeps your text.
  - The **Inbox** lists the suggestions waiting on your Mac. Swipe right to save one, left to reject it, or open it to **Edit & Save**. If your Mac doesn't take the answer, the suggestion comes back with the reason; one already answered on the Mac just leaves.
  - Every tab shows how your Mac is reachable at the top: "Connected to Maya's MacBook Pro · Wi-Fi" (or Tailscale, a VPN or a tunnel), "Connecting…", or "Mac not reachable · 3 captures waiting" with **Why?**, which says what to try: the same Wi-Fi, Tailscale, waking the Mac, or Local Network access. While your Mac can't be reached, Search and the Inbox say so instead of showing old results; nothing from the vault is kept on the iPhone.
- **Approve requests on the iPhone: the Mac's side.**
  - Settings ▸ iPhone has **Approve requests on this iPhone** for each paired iPhone, on by default.
  - When a Share, Save or access request waits on your Mac, Funes rings a "doorbell" in your own iCloud for each of those iPhones. The record holds only a random tag: no memory text, titles, task or agent name, and no request id. The iPhone then gets the details straight from your Mac, end-to-end encrypted. The record is deleted once the request is answered, expires or changes. Settings ▸ iPhone says when this Mac can't notify, for example when it isn't signed in to iCloud.
  - The first answer wins, on the Mac or the iPhone. If the iPhone answers first, the Mac's panel closes and says "Answered on Sam's iPhone." Answers from the iPhone show in Activity under its name, with the same 15-minute limit and the same checks as on the Mac.
- **Approve requests on the iPhone.**
  - When an agent asks to share memories, save one or get more access, the iPhone shows a notification, also locked: "Claude Code wants 3 memories", "Cursor suggests a memory", "Codex wants to read Work". It names the agent and the count, never your memories or the task. The iPhone words it itself, after asking your Mac over the encrypted connection; if it can't reach your Mac, the notification says "Mac not reachable".
  - Tapping it opens the same panel as the Mac's: where the text goes, what the agent says (not checked by Funes), and the memories with checkboxes and sensitivity badges, weaker matches unticked under "Also matched, less closely", each with its exact text and **Show All**. **Share N** or **Deny**, **Save** or **Discard**, **Allow Once**, **Not Now** or **Always Allow…** answer it. Answering needs the iPhone unlocked.
  - The first answer counts. If your Mac answered first, the iPhone says "Answered on your Mac"; if the memories changed meanwhile, it shows the new panel to review again; after 15 minutes it says the request expired.
  - Requests still waiting are listed under **Waiting for you** at the top of Capture, for a notification you missed.
  - Settings ▸ **Approve requests on this iPhone** turns them on or off, the same switch as on the Mac. It says why notifications might not come: notifications off, the iPhone or the Mac not signed in to iCloud, or a Mac build that can't notify. The iPhone asks for notification permission once approvals are on.
- **Demo mode on the iPhone.** Try every screen without a Mac, for App Review and for a first look.
  - **Try Demo** on Capture (and in Settings, Search and the Inbox) while the iPhone isn't paired opens a sample vault built into the app: about 20 memories, three Inbox suggestions, and a Share, a Save and an access request waiting under **Waiting for you**.
  - Search, edit, archive and delete, Save and Reject in the Inbox, and answer the requests, as with a real Mac. Captures go to the demo's Inbox.
  - An orange **DEMO** banner says "Demo vault: not your data" on every tab. Nothing in the demo leaves the iPhone or touches your pairing or your real captures, and **Leave Demo** discards its changes and captures.
- **Ready for the App Store.** The iPhone app and its extensions carry Apple's privacy manifests: no tracking and no data collected. The privacy statement and funesvault.com/privacy now cover the iPhone app, including the iCloud doorbell for approvals, and funesvault.com/support has an iPhone section.

### Fixed

- **The secret scanner blocks shorter passwords**, such as "password: testqwe1234". After `password`, `api_key`, `access_token`, `auth_token` or `client_secret` and a colon or `=`, a value of 8 or more characters that mixes letters and digits now counts as a secret; before, it needed 12. "password: see 1Password" and "my password is in the vault" still save. The Mac and the iPhone share the scanner.

## [0.1.4] - 2026-10-20

### Added

- **Appearance: Automatic, Light or Dark.** In Settings ▸ General, keep Funes Vault dark while macOS is light, or the other way round. Automatic follows macOS, as before. The choice applies at once to every window and panel and to the menu bar menu, and stays after a relaunch. EK Bridge has the same setting.

### Changed

- **Each agent has its own row in the sidebar**, like EK Bridge's connections. The order is now Vault, Inbox, Activity, then the agents with a **+** to add one, then Remote Access and **Settings…** pinned at the bottom.
  - An agent's row shows a short status ("2 min. ago", "Paused") and a badge counting its requests waiting for you. Its page shows those requests under its name, with its access summary.
  - The View menu follows the new order: Activity is ⌘3, Agents ⌘4 (the last agent you looked at) and Remote Access ⌘5.
  - The status line under the sidebar shows only while something's off: agents paused (with Resume), or the agent server off or stopped.

## [0.1.3] - 2026-10-20

### Added

- **The Share panel says where the text goes.** A "Goes to" line, built only from what Funes Vault knows: "Claude Code on this Mac. It may send what it reads to its AI service.", or for a cloud agent "claude.ai, through your Tailscale Funnel, to Anthropic's servers" with a **Cloud** chip.
- **Review Request (⌃⌥⌘R), from any app.** It brings a waiting panel forward and makes it key, so Return and Esc answer it; with no panel showing, it opens the newest pending request. The menu's first item does the same while something waits. Change or turn off the shortcut in Settings ▸ General.
- **More Time** on the Share panel moves the request to Pending requests at once, where it waits up to 15 minutes.
- **Never-share categories.** "A Few Questions" ends with "Which of these should agents never see?". The categories you tick get Deny for every agent, and new agents start with it; Categories keeps the list ("New agents can't read"). It replaces the question "What should Funes be especially careful not to share casually?", whose answer was saved as a memory that agents reading Internal could get.
- **Add and Connect…** For Claude Code, Claude Desktop, Cursor and Codex, Add Agent goes straight to the change to the agent's settings, then suggests a first question to ask it.
- **The capture box says when a cloud model sees the text:** "Goes to your Inbox · fields suggested by Anthropic". Settings ▸ Capture says it too.
- **Remote Access offers to move a Tailscale Funnel setup on port 8443 or 10000 to 443.** claude.ai and ChatGPT only connect to 443. Setups from 0.1.1's drafts, or on a port picked by hand, showed as **Running**, or got start commands for the old port.
  - Once 443 can take Funes Vault's paths, the Tunnel row says so and shows the four commands that add them to 443, then the ones that turn off the old port's entry.
  - Then **Address ▸ Edit…** changes the address to the one without a port.
  - BridgeKit 0.4.1.

### Changed

- **"Wants more access" makes Allow Once the default.** The panel is now "Cursor wants to read Project context", with Not Now and **Allow Once**; Always Allow is a link that names what it adds, never the Return key, and is never cut off.
- **The Share panel keeps the agent's words apart.** Task, keywords, purpose, how long it keeps what it gets and who it shares with sit in a block marked "The agent says · not checked by Funes". Your own note on the agent shows as "Your note", as the Access tab always promised.
- **Only strong matches start ticked.** Memories that matched less closely are offered unticked under "Also matched, less closely".
- **Requests on a clock come first.** When several panels wait, chips at the top show each one with its countdown, most urgent first, so a Save panel never hides a request that is running out. VoiceOver hears one announcement with the time to answer and the shortcut.
- **An access request nobody answered doesn't block the next one for an hour.** If the panel ran out or was withdrawn, Funes Vault may ask again; Not Now still waits an hour.
- **The Save panel shows the memory first**, then its details; Edit… is a link.
- **The cloud limit says what it limits:** "Never send captures above".
- **Setup connects first.** The checklist is now Connect an agent, Approve its first request, Seed your vault, Review your Inbox. Keyboard focus starts on the first step, not Hide, and Hide offers Undo. An empty vault shows a welcome instead of an empty list and filters.
- **Add Agent has two tabs,** On This Mac (agents found on this Mac first) and Cloud · Experimental, and agent names no longer get cut off.
- **Pending requests are easier to find:** above the Agents list, counted by the sidebar's Agents badge, with how many memories each would share and its task.
- **The menu bar icon is the app's eye.**
- **The sign-in panel:** Esc denies, it shows until when pairing is open, and VoiceOver reads the code digit by digit.
- **funesvault.com has a new design**, built around the app icon's eye. The privacy statement's section on the website now describes its one script: the Homebrew copy button, and the eye on the home page that follows your pointer. It sends and stores nothing.

### Fixed

- **The setup checklist's Add… opens Add Agent** even when the Agents page wasn't showing yet.
- **The Agents page fits the window at its minimum size.** At 860×560 the agent's detail ran off the right edge, cutting off **Remove…** and the switches. The list is narrower in a small window, the header's buttons move to their own line when they don't fit, and the agent's kind wraps instead of showing "claude….". The Vault's sort menu drops its "Sort by" label when the filter row would be too wide.
- **The Cloud tab fits its column and says up front where text goes.** "Text you share with a cloud agent goes to its vendor's servers…" is now the caption under **Allow cloud access**, not a last line below the fold with its left edge cut off. A long cloud agent name in the picker no longer widens the tab past the window.
- **Cloud setup steps point to the buttons on the same tab:** "click Connect a Cloud App… below" instead of telling you to open the agent you're already looking at. The same for Copy Remote Token… and Set Up OAuth Client….
- **Delete Now… in Recently Deleted always asks first.** The list's context menu deleted for good without a question; it now asks "Delete this memory now?", like the detail and the bulk bar, and all three are labelled **Delete Now…**.
- **Warnings and sensitivity badges are easier to read.** Badges show the level's name in primary text on its color (it was colored text on a light tint, about 2:1). Warnings on the Access tab, in AI Models, Settings and the import sheet are an orange icon with primary text instead of orange text. Increase Contrast darkens the icon and strengthens the badges.
- **A copy built from source never checks for updates**, as the privacy docs promised. Only copies signed with Funes Vault's Developer ID check GitHub; builds from source, Xcode runs and Debug builds don't, and they hide **Check for Updates…**. Before, every build checked, because the feed and the update key are in the committed `Info.plist`.
- **Activity fits the window again.** Since the Remote Access filter, the filter row was wider than the page at the default window size, so the page slid under the sidebar and cut off the title, Pending requests and the table's first columns. The agent and period pickers and search now move to a second line when the row doesn't fit, and the Event and Detail columns can get narrower, down to the window's minimum width.

## [0.1.2] - 2026-10-19

The first public preview. 0.1.0 and 0.1.1 were preview builds, kept on GitHub as pre-releases: everything in them below is in 0.1.2, with this fix in place of 0.1.1's.

### Fixed

- **Remote Access shares Tailscale Funnel's port 443 with other apps on your Mac**, such as EK Bridge's Remote Access. claude.ai and ChatGPT only connect to port 443, so 0.1.1's other public ports didn't reach them.
  - The guide now shows one command per path Funes Vault answers. Each adds only that path to port 443, so other apps keep their entries, and the address has no port.
  - The command to turn Funnel off removes only those paths.
  - If 443 has another app's tailnet-only entry, which Funnel would make public, the guide uses 8443 or 10000 and says that claude.ai and ChatGPT can't reach it there.
  - New Tunnel states: **Incomplete**, with the commands for the missing paths, and **No shareable port**.
  - After **Reset Path…**, the page shows the commands that move Funnel to the new path.
  - BridgeKit 0.4.0.

## [0.1.1] - 2026-10-19

A preview build, kept as a pre-release and superseded by 0.1.2. Everything in 0.1.0 below is in it, with this fix.

### Fixed

- **Remote Access shares Tailscale Funnel with other apps on your Mac.** The guide used to offer `tailscale funnel --bg 47627`, which takes Funnel's port 443 and replaces whatever another app serves there, such as EK Bridge's Remote Access.
  - It now checks what Funnel already serves and uses the first free public port: 443, 8443 or 10000. The address ends in that port, such as `https://my-mac.tail1234.ts.net:8443`.
  - If all three are taken, it says so and offers no command.
  - Another app's Funnel entry no longer shows as **Wrong port**.
  - The command to turn Funnel off only touches Funes Vault's own port.
  - BridgeKit 0.3.0.

## [0.1.0] - 2026-10-18

The first public preview of Funes Vault for the Mac: a menu bar app that keeps your personal context in a private vault on your Mac, and shares it with AI agents only as you allow. It needs macOS 15 or later, on Apple silicon or Intel.

### Added

- **Agents connect over MCP**, on this Mac only.
  - The app serves MCP on `127.0.0.1:47625`, a port you can change in Settings ▸ MCP. Agents reach it through the `funes-mcp` launcher inside the app, or directly over HTTP.
  - Agents can list your categories, request memories for a task (with keywords for the kinds of context that would help), pick up a request you answered later, and suggest memories.
  - Each agent has its own key, kept in a private file and stored in the vault only as a hash.
  - The protocol and security core is [BridgeKit](https://github.com/bereciartua/bridgekit) 0.2.0, shared with EK Bridge. It refuses JSON-RPC ids longer than 1,024 bytes, so every response fits its 200,000-byte limit.
- **You approve the exact text.**
  - A floating Share panel shows each memory an agent may get, with a checkbox per memory, the agent's task, keywords and stated purpose, and a 45-second countdown.
  - A request left unanswered says so on screen and waits in **Pending requests** for 15 minutes, where **Review…** opens it again with the minutes it has left.
  - Quitting Funes Vault while an agent waits tells the agent at once (`funes_quit`), and the request stays in Pending requests.
  - Shares always fit in one result of at most 200,000 bytes: memories that wouldn't fit are left out, like those over the agent's token budget.
  - An approval is used once, within 15 minutes, and is cancelled if a memory or the agent's access changes. Refusals tell agents how many memories were withheld and why, never which ones.
- **Agents**: add one from tiles for the agents found on this Mac, with a starting access.
  - The access editor sets what it can do (Read, Suggest, Write), its sensitivity limit, allowed and denied categories, whether Funes asks before sharing or saving, an expiry date, and whether it may ask for more.
  - Each agent shows whether it's waiting for its first request, connected, paused or expired. **Pause** and **Remove** are in its header; **Copy Key…** and **Rotate Key…** on its Connect tab.
  - **Connect** adds Funes to Claude Desktop, Claude Code, Cursor or Codex in one click, after showing the exact change and keeping a backup, and never writes the key. Copyable setups cover VS Code (Copilot), Gemini CLI, Zed, Cline, JetBrains AI Assistant, Devin Desktop and any other MCP client.
- **Remote Access for cloud agents** (experimental, off by default): claude.ai, ChatGPT, Gemini Enterprise, the Anthropic and OpenAI APIs, Claude Managed Agents, and the Claude Code, Cursor, Copilot and Devin cloud agents can reach Funes through a tunnel you run, such as Tailscale Funnel.
  - A Remote Access page with a four-step guide (choose a tunnel, turn on and start it, paste its address, test), the tunnel's commands for port 47627, checks on this Mac of whether the tunnel runs, **Test**, **Switch Tunnel…**, **Reset Path…**, an automatic turn-off and keep-awake.
  - Each agent has **Allow cloud access**, off by default, on a new **Cloud** tab, with the cloud agent's setup, **Copy Remote Token…** and **Reset Remote Token…**, connected cloud apps with **Revoke**, and **Connect a Cloud App…**, which opens a 10-minute pairing window for that agent. Add Agent has cloud tiles.
  - claude.ai and ChatGPT sign in with OAuth: a panel on the Mac shows the same six-digit code as the browser, and **Allow** works after a second.
  - A cloud agent gets exactly the access you set for it, with the same panels, 45-second wait and 15-minute pending list as any agent. Remote calls are marked in Activity (a cloud icon, "via Remote Access", and a Remote Access filter) and have a stricter rate limit on top of the agent's own.
  - The menu bar icon shows a globe while it's on, and the menu has **Turn Off Remote Access**. An optional notification says when the tunnel stops.
  - Built on BridgeKit 0.2.0's `BridgeKitRemote`, EK Bridge's Remote Access, shared.
- **Asking for more access**: an agent you allow to ask gets a panel when a request is refused only because of a category: **Not Now**, **Allow Once** (that request only) or **Always Allow**. At most once an hour per agent and category. A refused suggestion goes to the Inbox if you allow it.
- **The Vault**: search as you type, by meaning as well as by words, with filters by category, kind, sensitivity, status and source, and three sort orders.
  - Each memory opens in an editor with a character counter, categories, a sensitivity level with what it means, an optional expiry date, how often it was shared (linking to Activity), its history, and **Archive**, **Delete** and **Still True**.
  - **Recently Deleted** keeps memories for 30 days, with **Restore** and **Delete Now**.
  - Select several memories to archive, delete, move or change their sensitivity together. Rename categories, and add or delete your own. Saving a memory says when a similar one exists.
- **The Inbox**: suggestions from agents, captures, imports and your answers, each a card you can edit before **Apply**, **Reject** or **Later**.
  - Cards say who proposed the fields, quote the agent's reasons as reported, point out similar memories, and show a correction as old → new with **Replace** or **Keep Both**.
  - Select several to apply or reject them together. Expired suggestions can be restored for 7 days.
  - The **Save this memory?** panel appears when an agent suggests something, with **Edit…** to open it in the Inbox.
- **Activity**: what each agent asked for and what happened, by day, with filters (Shared, Suggestions, Problems), agent, period and search.
  - A row's details show the memories involved by their current title, what was withheld and why, and links to fix a refusal. Pending requests sit at the top with **Review…**.
  - Activity stores ids and reason codes only, never memory text.
- **Quick capture** with ⌥⌘M (changeable in Settings ▸ Capture), **Remember…** in the menu, or **Services ▸ Remember in Funes** in any app.
  - The box says when text looks like a secret, and saves nothing then.
  - Otherwise the capture goes to the Inbox, and the chosen model (Apple's on-device model by default, with rules as a fallback) proposes a title, kind, categories and sensitivity in the background.
- **Getting started**: a checklist at the top of the Vault (seed your vault, review the Inbox, add an agent, connect it), seven optional questions whose answers go to the Inbox, and imports from a ChatGPT memories file, pasted Claude memories, a Markdown file or a Funes Vault export. Each import is previewed (duplicates, secrets, over-long items) before anything is stored.
- **The menu bar**: the icon shows when Funes needs you or is paused. The menu has **Remember…**, the Inbox count, **Pending requests** with minutes left, **Pause Funes Vault** (for 1 hour, until tomorrow or until you resume, kept across relaunches), **Open Funes Vault** and **Settings…**.
- **Search on your Mac**: hybrid keyword and semantic search with the bundled [bge-small-en-v1.5](https://huggingface.co/BAAI/bge-small-en-v1.5) embedding model, run with Core ML on the CPU. No download, no API key, nothing leaves the Mac.
- **Settings ▸ AI Models**: embeddings are built in. Classification uses Apple's on-device model by default, or a provider you add: Anthropic, OpenAI, Ollama, LM Studio or another OpenAI-compatible server, with its key in the Keychain and **Test Connection**.
  - Each choice shows where it runs and, for cloud ones, what it sends. Classification sends only new captures and your category names and descriptions; agent suggestions and imports are never sent.
  - Nothing above the cloud limit (Internal by default), and nothing that looks like a secret, goes to a cloud model.
  - Usage counts per provider, with **Reset Usage**.
- **More settings**
  - **General**: open at login, show Funes in the Dock, and optional notifications: a request expired, a suggestion is waiting, an agent was refused more than 5 times in 10 minutes.
  - **MCP**: turn agent access on or off, change the port, see the address, the launcher (optionally linked as `~/.local/bin/funes-mcp`) and traffic counts.
  - **Data**: daily backups of the vault (keeping 7), restore a backup, export and import, show the data folder, and erase everything.
  - **Updates**: signed updates from GitHub through Sparkle, checked daily; installing always takes a click.
  - **Advanced**: how long Activity keeps rows, and bringing back the setup checklist.
- **Moving to Applications**: run from Downloads or a disk image, the app offers to move itself to Applications.
- **Accessibility**: every control works from the keyboard and has a VoiceOver label; panels, the capture box's errors and short notices are announced; badges and cards get stronger outlines with Increase Contrast, and notices don't fade with Reduce Motion.
- **Licences in the app**: the bundled embedding model ships inside the app with its MIT licence, and the app includes the licence texts of GRDB.swift, Sparkle and the model alongside its own `LICENSE` and `NOTICE`.
- **Open source**: the code, the product definition in `spec/`, and the tests are public under the Apache License 2.0. See [Testing](docs/TESTING.md) for what has been checked.

[Unreleased]: https://github.com/bereciartua/funes-vault-app/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/bereciartua/funes-vault-app/compare/v0.2.0...v0.5.0
[0.2.0]: https://github.com/bereciartua/funes-vault-app/compare/v0.1.4...v0.2.0
[0.1.4]: https://github.com/bereciartua/funes-vault-app/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/bereciartua/funes-vault-app/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/bereciartua/funes-vault-app/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/bereciartua/funes-vault-app/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/bereciartua/funes-vault-app/releases/tag/v0.1.0
