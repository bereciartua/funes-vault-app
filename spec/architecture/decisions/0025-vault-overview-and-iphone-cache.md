# ADR-0025: A vault overview of counts only, served to the iPhone, which caches it for Home and widgets

**Status:** Accepted · 2026-10-25 · **Amends** [storage §6](../storage.md#6-iphone-storage) and [UX: iPhone](../../product/05-ux-iphone.md) ("nothing is cached beyond the screen"), [companion protocol §4](../companion-protocol.md#4-methods) (a new method)

**Context.**
- **The web version had a Home** (`funes-vault`, its ADR-0029): a composer plus three signal cards safe to show if someone looks over your shoulder (memories over 30 days, the sensitivity mix, a rhythm grid). The author found it fun and useful, and wants it back on the Mac and the iPhone ([Phase 7](../../plans/phase-7-home.md)).
- **The native apps know more:** each memory's source, and every delivery to an agent. Disclosures are never purged, and `disclosure_item` records each delivered memory with its category and sensitivity. So the Home can also show what went **out** to agents, which the web couldn't.
- **The iPhone is a thin client:** today it keeps no vault data once a screen closes (storage §6). A Home whose charts vanish whenever the Mac is away, and widgets, which can't call the Mac themselves, both need a copy that outlives the screen.

**Decision.**
1. **`VaultOverview`** in FunesCore: one read that returns **aggregates only**, never memory text or titles:
   - new memories per day by source (`memory.created_at`, `memory.source`), over 12 months;
   - active memories by sensitivity, category and kind; the total;
   - memories delivered per day per agent (`disclosure` with `delivered_at`, joined to `disclosure_item`), and their sensitivity and category totals;
   - requests refused per day (`disclosure` with status `denied`), with their `withheld` totals by reason;
   - Inbox pending and the oldest pending date; the last tidy-up run; agent names, kinds and last-request times.
   It's computed by SQL over the existing tables, **with no new table**. If it takes more than 50 ms on a 10,000-memory fixture vault, indexes on `memory(created_at)` and `disclosure(delivered_at)` are added in the next migration. Purged memories drop out of the "in" history, which is fine for a chart.
   - **Amended 2026-10-25, when task 7.2 landed:**
     - It took 86–105 ms on the benchmark vault (10,000 memories, 8,000 delivered requests with candidate snapshots), and the 12 months still took 59 ms with the two plain indexes (on an earlier, lighter fixture), because the reads then visit rows holding memory text and snapshots. `v5_overview_indexes` adds five indexes that carry the columns each read groups by ([storage §3](../storage.md#3-migrations)): about 12 ms for 30 days, 14 ms for 12 weeks, 36 ms for 12 months. No rollup table. The budget check runs alone, outside CI (`FUNES_OVERVIEW_BENCHMARK=1`), since timings beside other tests or on shared runners say little.
     - The type, `VaultOverview`, is in FunesProtocol, shared by the Mac, the companion and the phone; the read is `VaultStore.overview(_:now:calendar:)` in FunesCore.
     - It also carries the **kind** totals, what was shared by **category**, the refused requests by **reason**, and **rhythm**: new memories per day over the last 12 weeks, whatever the range, for the Rhythm card and widget, which the weekly and monthly ranges can't give. "Withheld" is what the refused requests withheld. "This week" is the last 7 days, today included.
     - A memory typed on a paired iPhone (`memories.create`) is stored as `manual` with its device, and counts as iPhone.
2. **`overview.get`** on the companion protocol: `{range: 30d | 12w | 12m}` returns the same aggregates for that range, as the owner. Logged in Activity as `overview_viewed` (no counts), like the other reads.
3. **The iPhone caches the last answer** (amended 2026-10-25: the last answer **for each range**, so opening 12 months doesn't take the widgets' 30 days away), as `overview.json` in the App Group container (`OverviewCache` in FunesPhone):
   - numbers, dates and agent names only, never memory text or titles;
   - written atomically after each successful call, with file protection `completeUntilFirstUserAuthentication` (readable after the first unlock, which Lock Screen widgets need);
   - read by Home (shown at once at launch, dimmed with "As of 10:42" while the Mac is away) and by the widgets in the Intents extension;
   - deleted on unpair, on revocation, and when leaving the demo (whose own snapshot comes from the demo vault). Entering the demo deletes it too, so it's never a mix of both.
4. **Widgets never call the Mac.** They show the cache. The app refreshes it on foreground, pull to refresh, after captures are delivered and in its existing background refresh, then reloads the widgets' timelines.

**Consequences.**
- **A small, labelled exception to "no vault data on the phone":** counts and agent names, which say how the vault is used but nothing it contains. PRIVACY.md and the App Store privacy notes say so when the code lands.
- **The Lock Screen** can show counts while the phone is locked; agent names in widgets are marked privacy-sensitive, so iOS redacts them while it's locked.
- **No schema change** unless the benchmark asks for the two indexes.
- **Widgets are as fresh as the app's last contact** with the Mac, and say "as of" once that's over an hour old.

**Alternatives considered.**
- **No cache (as today):** Home is half empty away from home, and widgets are impossible.
- **A rollup table on the Mac** (`daily_stats`, kept current on writes): faster at scale, but the vault already holds everything needed, and a second copy of the truth can drift. Revisit only if the benchmark fails even with indexes.
- **Reading the Activity log:** it's JSONL with a 30-day retention for most rows, and compaction; the database is the better source.
- **Caching search results or memories for offline reading:** a much bigger exception, with memory text on the phone. Not needed for Home or widgets; not done.
