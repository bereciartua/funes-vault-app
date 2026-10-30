# Phase 9: Search answers

**Goal:** get to the fact without opening memory after memory. First, search snippets show the sentence that matches. Then, when you ask, the model you chose reads the top results and answers, quoting the memory behind every claim, on the Mac and the iPhone.

**Duration:** about 2.5–3 weekends (a guess until Spike F). **Depends on:** nothing unfinished. **Decision:** [ADR-0028](../architecture/decisions/0028-search-answers.md). **Specs:** [memory processing §10](../domain/memory-processing.md#10-search-snippets-and-answers), [model providers §1, §3–6, §9](../architecture/model-providers.md), [companion protocol §4, §7](../architecture/companion-protocol.md#4-methods), [security and privacy T37, §5](../architecture/security-and-privacy.md), [UX: Mac ▸ Vault, Settings](../product/04-ux-mac.md#vault), [UX: iPhone ▸ Search, Settings, Demo mode](../product/05-ux-iphone.md#search-tab), requirements FR-V-17, FR-AI-17, FR-iOS-13.

**Order:** 9.1 → 9.2 → 9.3 → 9.4 and 9.5 → 9.6. 9.1 ships on its own and is used for a few days before 9.3 starts. 9.7 is optional and later. All of it lands in one PR, with the spec, so each step is a commit or a few, not a release.

## 9.1 Snippets · ½ weekend
- [ ] **`SearchTerms`** in FunesProtocol: the search's non-stopword terms and the light stem, moved from `SearchService` and the finder so FunesCore, the Mac app and the iPhone share one rule; tests that keyword search's terms don't change.
- [ ] **`PassagePicker`** in FunesCore `Search/`: sentence split (`NLTokenizer` `.sentence`, line breaks, 300-character pieces), the keyword score with the adjacency bonus, the best sentence with optional context. Tests: ties, no match, a long single sentence, a match in the last sentence of a 10,000-character body, Spanish and accented text.
- [ ] **Snippets** (§10.2): the trimming around the first match with "…", word boundaries, the short-body and empty-search cases; used by `CompanionHandlers.snippet` (with the query) and the Vault's preview.
- [ ] **Budget:** a test that search with snippets stays within FR-V-10's 150 ms on a 10,000-memory vault (the existing benchmark vault), and that a snippet is always a verbatim slice no longer than 160 characters.
- [ ] **Highlighting:** the Vault's list row and the iPhone's `SearchView` highlight the search's terms with `SearchTerms`. VoiceOver reads the snippet as plain text.
- [ ] Use it for a few days; note in this plan which searches still needed opening memories (they become Spike F questions).

## 9.2 Spike F: answer quality · ½ weekend
Throwaway code in `spikes/search-answers/`, like Spike E. **Ask the author before any cloud run** and say what it uses of their plans (Spike E's cloud runs: about 7 s and 6–9k tokens a Codex call, about 5 s and 3k tokens a Claude call).
- [ ] **Fixtures** (synthetic; the repo is public): about 40 questions over the Spike 2 benchmark vault (`memories-200`, with dates) and a few added memories: buried facts in long bodies (imports), superseded values (an old and a new title), conflicts, negation ("doesn't eat meat"), facts about other people, questions with no answer in the top 8, a question whose answer is above the cloud limit, and an injection inside a memory. Each with the expected claims (keys, as Spike E scored), the acceptable abstention, and whether it's answerable. Plus about 20 held-out questions written blind by GPT-6-Astra, as Spike E's second set.
- [ ] **Harness:** runs search for each question (the real FunesCore ranking, via the test server or a small script target), builds the prompt of §10.3, calls the provider, applies §10.4's validation, and scores: correct claims (precision of surviving claims), right "no answer", answered among answerable, claims dropped by validation, conflicts reported, latency p50/p95.
- [ ] **Providers:** Claude Haiku 5.5 (Claude Code), GPT-5.6-Terra and GPT-6-Luna (Codex), and one Apple on-device run on the questions that fit its 5 × 600 characters, for the record.
- [ ] **Gates** for shipping 9.3–9.5 with a provider as the suggested default: correct claims ≥ 95%, right "no answer" ≥ 90%, answered ≥ 80% of answerable, p95 ≤ 15 s. Quote validity isn't a gate: it's §10.4's code, tested in 9.3.
- [ ] **Record** a "Spike F" section in [spike results](spike-results.md), and update memory processing §10 and ADR-0028 where the numbers move (top 8, 1,500 characters, 45 s, the prompt rules).

## 9.3 Core · ¾ weekend
- [ ] **`SearchAnswerer`** in FunesCore: memory selection (top 8 active, unexpired; 5 on-device), cloud-limit filtering before the prompt with `withheld`, passages by keyword plus semantic score (the cached query vector, sentences embedded as documents with bge-small), the prompt and the strict schema of §10.3.
- [ ] **Validation** (§10.4): refs, quote normalization and bounds, claims dropped for any failed quote, the 3-claim and 300-character limits, the secret scanner over the claims, highlight ranges in the current body. Table-driven tests from recorded model outputs, including Spike F's.
- [ ] **ModelRouter:** a `searchAnswer` task with its provider setting (Same as New memories, or its own), the search text as a `query` item (secret scanner; the limit on memories only), the 45 s timeout, no fallback, one cap count per attempt, not in the agents' share. `scripts/test.sh`'s check that nothing else calls `generate` still passes.
- [ ] **Cancellation:** cancelling the task ends a subscription CLI's child process and an HTTP request; a test with a stub CLI that sleeps.
- [ ] **Activity:** `search_answered` (outcome, reason, engine, duration, `read`, `withheld`, `claims`, `dropped`, actor); never text (the log privacy check, and a test that no row holds the search or a claim).
- [ ] **Guardrail tests:** request capture with sentinel strings at each sensitivity and secret samples: nothing above the limit and no secret in a cloud prompt; a local server gets every memory (the scanner still applies).

## 9.4 Mac · ½ weekend
- [ ] **Settings ▸ AI Models ▸ Search answers:** Answer (Off · Only when I ask), Model (Same as New memories, or a provider and model), status, caption, disclosure line. Stored with the other task assignments in user defaults.
- [ ] **Vault:** the Ask row and ⌘⏎ (Active scope, non-empty search, results), the reading card with Cancel, the answer card (claims, chips, quotes, badge, footer, Copy, Clear), the chips on cited rows, the highlight in the detail, every message of §10.5. Clearing on search, scope and filter changes. Rows never move; nothing is selected automatically.
- [ ] VoiceOver labels (the card reads its claims, then "Source 1: <title>"), the string catalog (`sh scripts/sync_strings.sh`), UI snapshots (`vault-answer`, `vault-answer-none`, `settings-models` with the new row; light and dark).

## 9.5 iPhone · ½–¾ weekend
- [ ] **Companion (Mac):** `searchAnswers` in `status.get`; `memories.answer` in `CompanionRouter` and `CompanionHandlers` with its 50 s deadline, the error codes, one call in flight per device (a new one cancels the previous), cancellation when the connection closes, Activity under `device:<id>`. Tests against the real router, as for the other methods.
- [ ] **Companion (phone):** `CompanionClient`'s timeout per method (55 s for `memories.answer`, 15 s otherwise), never resent; the new errors as typed `CompanionClientError` cases that `ReachabilityTracker` doesn't count as unreachable.
- [ ] **`SearchModel`:** an answer state (idle, reading, answered, no answer, failed) tied to the query, scope and filters, cancelled when they change or Search disappears; the ids of the first 8 results shown. Tests in FunesPhone, including a slow answer overtaken by a new search.
- [ ] **UI:** the Ask pill, the card as the list's first section, Cancel and Clear, numbers opening the memory detail with the quote highlighted, the messages; Settings ▸ Search answers (Show Ask in Search, "Answered by"). String catalog, screenshot scenes.
- [ ] **Demo mode:** canned answers in `DemoVault` for the three sample questions, citing its memories; the hint for any other search; no network.

## 9.6 Ship · ¼ weekend
- [ ] README (Search answers in the feature list), PRIVACY.md (the search text and top results go to the chosen Search answers provider, only when asked), docs, CHANGELOG.
- [ ] `sh scripts/test.sh` green; the iPhone app builds for a generic device; a TestFlight build with the author's go-ahead.
- [ ] The author uses it for a week; note bad answers here.

## 9.7 Later, optional: automatic for questions
- [ ] Only if a provider shows p50 ≤ 3 s and p95 ≤ 5 s on the author's Mac under normal load (measured with Spike F's harness): Answer gains "Automatically for questions" (a search ending in "?" or starting with a question word in English or Spanish, after a 0.6 s pause), falling back to the Ask row when the provider is slower. Needs its own short ADR amendment.
