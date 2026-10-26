# Phase 8: About you

**Goal:** Funes knows who you are. A small profile in Settings ▸ About You (your name, what to call you, pronouns, languages, location, time zone, occupation). Home greets you by name on both apps, and each agent gets the fields you tick for it, with its answers to `request_memory`.

**Duration:** about 1.5–2 weekends. **Depends on:** nothing unfinished. **Decision:** [ADR-0026](../architecture/decisions/0026-about-you-profile.md). **Specs:** [domain model ▸ Profile](../domain/domain-model.md#profile), [access policy §3.10](../domain/access-policy.md#310-the-profile) (T36–T46), [MCP server §6.2](../architecture/mcp-server.md#62-request_memory), [storage `v6_profile`](../architecture/storage.md#3-migrations), [UX: Mac ▸ Home, Agents, Settings, Share panel](../product/04-ux-mac.md), [UX: iPhone ▸ Home](../product/05-ux-iphone.md#home-tab), [companion protocol `status.get`](../architecture/companion-protocol.md#4-methods), requirements FR-U-01..05.

**Order:** 8.1 → 8.2 → 8.3 and 8.4 (either order). Each step ships on its own; the Mac and iPhone apps are updated together.

## 8.1 Core · ½ weekend
- [x] **`Profile`** in FunesProtocol (shared with the phone for the called name), with its limits and the called-name rule; `ProfileField`.
- [x] **`v6_profile`**: the `profile` table, `access_profile_field` (with `name` for every agent not removed), `disclosure.profile_fields_sent`; the fixture test from a version 5 vault.
- [x] **`VaultStore`:** read and save the profile (trimmed, empty as none, the secret scanner over every field, in one transaction); `profile_edited` in Activity with field names only.
- [x] **Access:** `profileFields` in `Access`, saved with the rest of the editor's changes, bumping the revision; new agents get `{name}`.
- [x] **Policy:** §3.10 in the request path: after the gate, whatever the outcome; only the agent's set fields; the Mac's time zone for `automatic`; `profileFieldsSent` on the disclosure and the Activity row. Test vectors T36–T46.
- [x] **Bundle:** the profile's encoded size kept back from the result-size limit before items are added; a test at the limit.
- [x] **Export and import:** `profile` in `funesvault.export.v1`; restored only into an empty profile; Erase All Data clears it.

## 8.2 MCP · ¼ weekend
- [x] `profile` in `request_memory`'s output schema (every key optional) and the new server instructions, in `mcp-tools.json`; goldens regenerated (`UPDATE_GOLDENS=1`).
- [x] The Python harness: a seeded profile; `profile` present after the gate (T36, T39), absent for gate denials (T37, T38) and on `get_memory_request` (T44); the same over Remote Access (`remote_test.py`).
- [ ] Check with Claude Code and one cloud agent that they use the name ("What's my name?" and a cover-letter task); record it with the live matrix.

## 8.3 Mac · ¾ weekend
- [ ] **Settings ▸ About You**, the first pane: the fields, the account name as placeholders and **Use "<name>"**, the scanner's error per field, the language picker and the time zone list, "Shared with" counts and their agent lists.
- [ ] **Home's greeting** by the called name, plain without one; `HomeText.greeting` takes the profile instead of `NSFullUserName()`.
- [ ] **Agents ▸ Access:** the About you checkboxes with each value dimmed, disabled without Read; the header summary ("· knows your name").
- [ ] **Share panel:** the "also has your name and pronouns" line, linking to the agent's Access tab.
- [ ] **Activity:** "Also sent: name, pronouns" in the detail pane; "Edited About you · Pronouns" rows.
- [ ] **Seed questions:** the first page, "First, what should Funes call you?", prefilled only when the account's name looks like a person's; Skip.
- [ ] VoiceOver labels, string catalog, UI snapshots (`settings-about-you`, the Access tab, Home with a name; light and dark).

## 8.4 iPhone · ¼ weekend
- [ ] `calledName` in `status.get` (FunesCompanion) and `CompanionClient`; the phone keeps the last one in the pairing record and drops it with the pairing.
- [ ] Home's title: "Good afternoon, Martin", truncating; the demo vault's sample name.
- [ ] Tests in FunesPhone (kept across launches, removed on unpair and revocation, never in the demo after leaving it); string catalog; screenshot scenes.

## When the code lands
- [ ] README (what agents receive), PRIVACY.md (the profile fields as something that can go to agents), docs, CHANGELOG.
