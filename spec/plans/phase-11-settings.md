# Phase 11: Settings

**Goal:** a Settings window a first-time user can find their way around, with AI split into what it does, where models come from, and what may leave the Mac; and a different model per job on one account.

**Duration:** about 3 weekends: 2.5 to build, ½ to check (the conversion's edge cases, navigation by keyboard and VoiceOver, every snapshot). **Depends on:** nothing unfinished. Phase 10 (the menu bar panel) is planned in parallel; see 11.6 for the Settings paths it names. **Decision:** [ADR-0030](../architecture/decisions/0030-settings-window.md). **Specs:** [UX: Mac ▸ Settings](../product/04-ux-mac.md#settings), [model providers §2 and §4](../architecture/model-providers.md#4-configuration-settings--ai), requirements FR-AI-05, -06, -12, -16. **Control map:** [below](#control-map).

**Order:** 11.0 → 11.1 → 11.2 → 11.3 and 11.4 → 11.5 → 11.6. One PR for the spec (the first commit on `spec/settings-redesign`) and the code, a commit or a few per step.

## 11.0 Navigation prototype · ⅛ weekend
- [ ] In the real `SettingsWindowController`: a `NavigationSplitView` with the sidebar toggle removed and a fixed sidebar width, a `NavigationStack` in one pane with a page, the toolbar back button and title, ⌘[, and a deep link straight to a page. Check on the oldest and newest supported macOS that the sidebar can't be collapsed or dragged and that the minimum size holds. If it can't, use the fallback of ADR-0030 §1 (a `List` beside the detail) and note it in the ADR.

## 11.1 Accounts and models · ¾ weekend
- [ ] **FunesCore `Models/AISettings`** (no localized text): the stored shape of ADR-0030 §6: accounts (endpoint, name, `models`), plans (`kind`, `models`), the three kinds of choice for New memories, Daily tidy-up and Search answers (with unresolved `ModelChoice`), the embedding choice, cloud limit, daily cap, Codex's file-read flag, usage by account, calibrations, the search answers switch and trigger.
- [ ] **Resolution:** each job's effective choice (following New memories where it does; never Apple on-device for the tidy-up; unresolved never borrowing), "Used by" per account (direct, following, second index), the picker entries with their can't-run reasons, and what removing a model or an account resets, as facts the app turns into words.
- [ ] **Conversion** from today's `AIModels` JSON, as ADR-0030 §6 says, written back at once. Fixtures: providers with and without a model; plans with a model, a blank model, no record; nil (follows) and `apple.foundation`; each task pointing at a model-less provider (stays unresolved, so Search answers doesn't start following a cloud New memories); already converted; nothing stored.
- [ ] **`ModelSettings`** reads and writes through it, and builds clients with the choice's model: `makeRouter`, `makeTidyUpRouter`, `searchAnswerRouterBuilder`, and `subscriptionClient(_:model:)` (Search answers' Test and status call it today with the plan's one model). `upsert` restarts the second index only for its account's address, key or cloud flag. `remove(account)`, `remove(model, from:)`, `addUsage`, `collectUsage`, `resetUsage(for:)`.
- [ ] **Every consumer, by name:** `SearchAnswersController` (`engine()`, which feeds the iPhone's `status.get`, now checks the choice's model, not `provider.model`, and `engineName` becomes "<account> · <model>"; its error links), `TidyUpController` (`tidyUpName`, `canTidyMemory`, errors), `ProcessingRunner` and `ImportSheet` (`chosenName` for splitting), `ProcessingCard` (engine name), `CaptureSettings` (`cloudClassifierName`), `EmbeddingController` and `EmbeddingRows` (embedding providers are OpenAI-compatible accounts), `DataOperations` (Erase All Data removes every account and key), `UIReview`.
- [ ] **Tests:** three different models on one account, one per job; following and unresolved choices; removing a chat model (direct and followers, embeddings untouched) and an account (second index cleared); usage and CLI blocking per account across models; calibration ids; the tidy-up's auto-apply level following its chosen model; the search answers trigger with Apple on-device; the cloud limit and Calibrate still re-embedding (lowering the limit deletes vectors now above it and stops sending them) while renaming an account or editing its chat models doesn't; a model change on the same account, directly or through New memories, changing the engine name in `status.get`, and `SearchModel` clearing its card on it (FunesPhone); that a converted setup routes each job to the same endpoint, model and key as before.

## 11.2 The window · ½ weekend
- [ ] **`SettingsView`** as 11.0 settled: the sidebar (profile row, groups, icons), a `NavigationStack` per pane, back within the pane, the title. `SettingsWindowController`: 820×600, at least 760×520.
- [ ] **`SettingsDestination`** replaces `SettingsTab` (`AppModel.settingsTab`, `openSettings(_:)`, `FUNES_DEBUG_OPEN=settings:<destination>`), with the UX table's names and a filesystem-safe form for snapshots; the last pane is remembered for the session, General the first time; a missing account opens Models & Accounts.
- [ ] **Panes that only move:** General with Updates folded in; Notifications split out; Capture & Shortcuts with the Review Request recorder; Agent Server (today's MCP view and its caption); iPhone, Data & Backups, Advanced and About You as they are.
- [ ] Keyboard (sidebar arrows, Tab, ⌘[) and VoiceOver (the list, headings, the profile row, the back button), checked by hand.

## 11.3 AI ▸ Features · ½ weekend
- [ ] **The pane:** the four job rows (summaries, trailing model and badge, the problem labels from configuration), Review ▸ Apply changes automatically, "What leaves this Mac ›".
- [ ] **Pages:** New memories, Daily tidy-up and Search answers from today's `ModelSettingsPane` rows, with the grouped pickers, unresolved choices and Add a Model…; Search index from `EmbeddingRows`, "Provider model" renamed "Second index". Status, captions and disclosure lines keep their logic, fed the chosen model.

## 11.4 AI ▸ Models & Accounts · ½ weekend
- [ ] **The pane:** groups by kind and resolved locality, rows with Used by and state, Add Account… (today's sheet, then the new page).
- [ ] **Account page:** Connection fields saving per field, the key's Save Key / Remove Key rules and Keychain error, Models (Add, Load Models, Remove with its confirmation naming direct jobs and followers, the embedding-model warning), Used by, Test with a model pop-up (its result naming that model), Usage with Reset Usage, Remove Account… with its confirmation (jobs and the second index).
- [ ] **Plan page:** the state line, Codex's switch and warning, Models (suggestions to start, Add, Remove but never the last), Used by, Test, Usage with Reset Usage, caption and privacy link. `SubscriptionRow`'s state text and test logic reused.

## 11.5 AI ▸ Privacy & Limits · ¼ weekend
- [ ] The cloud limit with its confirmation, the daily cap with today's line, and What AI features send by ADR-0030 §5's rules (splitting with proposals off, the tidy-up unscheduled, the effective trigger, the agent-request switch, Nothing). The facts come from FunesCore and are tested there (local only, a plan, an API key, Nothing, splitting with proposals off, a tidy-up with no schedule); the words stay in the app, so the string catalog sees them.

## 11.6 Words, snapshots, ship · ¼ weekend
- [ ] **Paths in strings:** the 18 user-facing "Settings ▸ AI Models" strings (3 on the iPhone), "Settings ▸ MCP" in the launcher, and the buttons that open Settings, pointed at their destination by ADR-0030 §9's rule. `sh scripts/sync_strings.sh`.
- [ ] **UI review:** a snapshot per pane and page, light and dark, named `settings-<safe destination>-light|dark` (replacing `settings-<tab>-…`), with fixed review data: an API account with two models, the Claude plan with two, a different model per job; and problem scenes: a missing key, a blocked plan, an uninstalled plan with usage, an account with no models, an unresolved choice, an embedding error. `sh scripts/ui_snapshots.sh` and a look at every one.
- [ ] **Spec and docs:** the paths ADR-0030 leaves for this step; README, PRIVACY.md and docs; CHANGELOG. If Phase 10 (menu bar panel) has landed, its Settings paths too (Review Request in Capture & Shortcuts, `agent-server` for its Fix… and Turn On…, Features ▸ Search answers), and its panel's Settings links get destinations.
- [ ] `sh scripts/test.sh` green; the iPhone app builds; a build for the author, who uses it for a few days before release.

## Control map

Every control in today's Settings (`main` at `5213a14`), and where it lands. "Same" means the control, its text and its behaviour don't change, only its place. Nothing is removed.

| Today | Control | New place | Change |
|---|---|---|---|
| About You | Name, Call me, Use "…", Pronouns, Languages, Location, Time zone, Occupation, Shared with | About You (profile row) | Same |
| General | Appearance | General | Same |
| General | Open Funes Vault at login, approval line, error | General | Same |
| General | Show in Dock | General | Same |
| General | Review Request shortcut (Turn Off, Use ⌃⌥⌘R) | Capture & Shortcuts ▸ Shortcuts | Moved |
| General | Four notification switches, "never include memory text" | Notifications | Moved |
| Capture | Quick capture shortcut, Turn Off, Use ⌥⌘M, Try It | Capture & Shortcuts ▸ Shortcuts | Same |
| Capture | Sensitivity for new captures | Capture & Shortcuts ▸ New captures | Same |
| Capture | Proposals caption, cloud disclosure label | Capture & Shortcuts ▸ New captures | "AI Models ▸ New memories" becomes "Features ▸ New memories" |
| Capture | "AI Models…" link | "New memories…" link to `ai.features/new-memories` | Renamed |
| Capture | Services hint | Capture & Shortcuts ▸ From other apps | Same |
| AI Models | Embeddings: built in, Status | Features ▸ Search index | Same |
| AI Models | Provider model, Load Models, Use…, confirmation, progress, Cancel, Retry, Calibrate…, Embed agent requests…, disclosure, Stop Using… | Features ▸ Search index | "Provider model" renamed "Second index" |
| AI Models | New memories picker, locality badge, status, disclosure | Features ▸ New memories | Picker lists account · model |
| AI Models | Propose a title, kind and categories | Features ▸ New memories | Same |
| AI Models | Split into separate memories, caption | Features ▸ New memories | Same |
| AI Models | Daily tidy-up (Off/Daily, time), Tidy Up Now | Features ▸ Daily tidy-up | Same |
| AI Models | Tidy-up model, caption, disclosure | Features ▸ Daily tidy-up | Picker lists account · model |
| AI Models | Search answers (Answer), model, status, caption, disclosure | Features ▸ Search answers | Picker lists account · model |
| AI Models | Apply changes automatically, caption | Features ▸ Review | Same |
| AI Models | Cloud limit, caption, confirmation above Internal | Privacy & Limits | Same |
| AI Models | Cloud requests per day, today's line | Privacy & Limits | Same |
| AI Models | Claude (Claude Code): state, model, Choose, Test Connection, privacy link | Models & Accounts ▸ its page | One model becomes a list; usage shown (counted today, never shown) |
| AI Models | ChatGPT (Codex): the same, plus the file-read switch and warning | Models & Accounts ▸ its page | One model becomes a list |
| AI Models | Plans' caption ("Uses your plan's limits…") | The plan's page | Same |
| AI Models | Providers list: name, locality, base URL, usage line, key state | Models & Accounts rows and account pages | Usage moves to the page |
| AI Models | Edit… (sheet: Name, Base URL, API key, cloud flag, Chat model, Choose, Load Models, Test Connection) | The account page | Saves per field; Chat model becomes Models |
| AI Models | Remove (deletes the key, usage, its jobs' choices and the second index) | The account page ▸ Remove Account… | Same effects; now asks first, naming the jobs and the second index |
| AI Models | Add Provider (presets, Other OpenAI-Compatible Server…) | Models & Accounts ▸ Add Account… | Renamed; opens the page after Add |
| AI Models | Reset Usage (all providers and plans) | Each account's and plan's page ▸ Reset Usage | Per account |
| AI Models | "Keys are stored in the Keychain…" | Models & Accounts | Same |
| MCP | Let agents connect, Status, Port, Change Port, Address, port warning | Agent Server | Pane renamed |
| MCP | Launcher path, Link, Remove Link | Agent Server | Same |
| MCP | Traffic since launch | Agent Server | Same |
| iPhone | Allow iPhone access, caption, status and warnings | iPhone | Same |
| iPhone | Same Wi-Fi, Tailscale (detected address or setup line), Public tunnel | iPhone | Same |
| iPhone | Public host, the forwarding URL, Reset Path and its caption | iPhone | Same |
| iPhone | Paired iPhones: detail, Remove… and its confirmation, Approve requests on this iPhone, notification note, Pair iPhone… (QR, Allow, Deny), five-iPhones line | iPhone | Same |
| Data | Backups, Back Up Now, Restore…, integrity warning | Data & Backups | Pane renamed |
| Data | Keep earlier versions, confirmation | Data & Backups | Same |
| Data | Include archived, Export…, Import… | Data & Backups | Same |
| Data | Location, Show in Finder, Erase All Data… | Data & Backups | Same |
| Updates | Check every day, Last checked, Check Now, the no-updates message | General ▸ Updates | Moved |
| Updates | Version | General ▸ Updates | Moved |
| Advanced | Activity retention, Restore Defaults | Advanced | Same |
| Advanced | Show the Setup Checklist Again | Advanced | Same |

**New:** the Features rows and their summaries; Models & Accounts' groups, "Used by" and states; account pages; each account's Models list; Add a Model… in job pickers; the per-model test pop-up; Save Key and Remove Key; "What AI features send" in Privacy & Limits; "What leaves this Mac ›" on Features.
