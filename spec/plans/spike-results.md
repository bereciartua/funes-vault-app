# Spike results

Results of the [Phase 0 spikes](phase-0-spikes.md). Each section gives the question, what was run, the numbers, and the decision it feeds.

---

## Spike 1: Companion transport

**Question:** can an iPhone pair with the Mac by QR code, send signed, HPKE-sealed requests over the same Wi-Fi and Tailscale, and deliver queued captures exactly once ([plan](phase-0-spikes.md#spike-1-companion-transport-pairing-encryption-offline-capture))?

### Run 1 (2026-10-21): **1a–1c, 1e, 1f and 1g pass** (1e after two fixes); 1d and 1h wait for task 5.4
**Setup:**
- **Phone:** iPhone 13 mini (iPhone14,4), iOS 27.0.1, running a Debug build of the iPhone app from task 5.3 (PR #33), signed for development.
- **Mac:** M-series MacBook Air, macOS 27, running a Debug build of the Mac app (Apple Development signing) with a development vault: `FUNES_DATA_DIR`, `--dev-seed`, companion port 47636, Same Wi-Fi and Tailscale on.
- **Network:** Wi-Fi 10.0.0.0/24. On the tailnet, the Mac is 100.89.20.22, and a Linux node advertises the subnet route 10.0.0.0/24.

| # | Scenario | Result |
|---|---|---|
| 1a | Pair on the same Wi-Fi | ✅ Paired on the first scan once Local Network was allowed, with the Allow click, over the LAN address. The Mac logged `device_paired` and then the first `status.get` over `lan` 4 s later. The phone's "Took X s" wasn't noted. |
| 1b | Capture → delivered on the same Wi-Fi | ✅ Accepted in 42 ms. One `capture_receipt`, an Inbox suggestion, and Activity `capture … queued` under `device:<id>` via `companion`. The phone-side deletion waits for 5.4's queue. |
| 1c | Response dropped after the commit | ✅ for the duplicate half: the same `captureId` resent was accepted in 69 ms, the Mac still has one receipt, and Activity says `duplicate`. Not tested by killing the connection on the device; `FunesPhone`'s tests drop the answer in software. |
| 1d | Mac asleep, 3 captures, wake | ⏳ Needs the capture queue (task 5.4). |
| 1e | Tailscale (phone on cellular) | ✅ after two fixes: **Connected · Tailscale** on 5G, round trip 462 ms, a test capture accepted in 287 ms, and the Mac recorded the transport as `tailscale`. The first tries failed twice, once on the Mac's listener and once on ATS; see below. |
| 1f | Tampered ciphertext, replayed nonce, skewed clock | ✅ From the phone, with its **Secure Enclave** signing key: good envelope `ok`, the same envelope again `replay`, tampered ciphertext `invalid_signature`, clock 5 minutes behind `clock_skew`. |
| 1g | Local Network prompt and Bonjour | ✅ Answering **Don't Allow** at the prompt gave "Funes isn't allowed on your local network…", since the browse reported `PolicyDenied`. Turned on in Settings ▸ Privacy & Security ▸ Local Network, pairing then worked. The Mac advertises `_funes._tcp` with TXT `v=1`, `mac=<tag>`. |
| 1h | Background delivery | ⏳ Needs `BGAppRefreshTask` (task 5.4). |

**1e, the passing run:** iPhone on 5G, Tailscale connected, "Use Tailscale subnets" off. The Mac ran PR #34's Debug build with the BSD-socket listener; the iPhone ran PR #33's build, which sends plain HTTP over Network.framework. The probes showed:
- `tailscale http://100.89.20.22:47636`: `ok`;
- the LAN IP: "Network is down" at once;
- the `.local` name: timed out after 3 s.

So Tailscale won about 3 s after the check started, once the better-ranked probes had finished.

**ATS, the second cause:** with the Mac's listener fixed, the phone still never reached 100.x; Safari did. The Debug probe readout showed **`URLError -1022`**: App Transport Security refuses plain HTTP to Tailscale's `100.64.0.0/10` addresses even with `NSAllowsLocalNetworking`, which covers only `.local` names and private ranges, so nothing left the phone. Since then the iPhone sends plain HTTP (LAN and Tailscale) through its own small HTTP/1.1 client on Network.framework, which ATS doesn't govern (`NetworkHTTPTransport`), and keeps `URLSession` for the tunnel's HTTPS. This is the outcome the spike's fallback "ATS trouble with Tailscale IPs" was about. The answer is a different transport, so the tunnel isn't needed for remote access.

**1e in detail, the first tries:**
- **First try, cellular with Tailscale's subnet routes on:** the phone showed "Connected · Wi-Fi" at a 192 ms round trip. It had reached the Mac's **LAN address**, 10.0.0.118, through the subnet router. The router presents the traffic as coming from a LAN address, so the Mac recorded the transport as `lan`. ATS allowed plain HTTP to that IP literal over the VPN.
  - **Label fix:** the label said "Wi-Fi" on 5G. It now reads **Connected · VPN** when a LAN address answers while the phone isn't on Wi-Fi or Ethernet.
  - **What this means:** with a subnet router, Same Wi-Fi mode is reachable from the whole tailnet. The envelope still protects every request; [companion protocol §5](../architecture/companion-protocol.md#5-transport-and-reachability) now says so.
- **Second try, subnet routes off on the phone:** "Checking…", then **Mac not reachable**. The Mac's 100.x address didn't answer.
  - **The cause is on the Mac:** the companion's `NWListener` gets the inbound flow on `utun5` (Tailscale), but Network.framework's own TCP handling never finishes the handshake (`nw_channel_reclassify_input … can't find client for slot`, then `connect_stalled`).
  - **Reproduced from the Mac itself,** connecting to its own 100.x address: every `NWListener` variant times out (plain, `allowLocalEndpointReuse`, with or without Bonjour, interface type `other`), while a POSIX socket listener (`python3 -m http.server`) answers. An IPv4-only `NWListener` mostly answers on 100.x but became flaky on the LAN address.
  - **Not ATS, and not the phone.**
- **Next:** fix the Mac's listener so it accepts on Tailscale's interface, for example by accepting with a BSD socket, or a separate IPv4 listener for the Tailscale address. Then run 1e again. Until then, the spike's fallback "use the tunnel only for remote access" isn't needed: the problem is local to the listener.

**Notes:**
- **Pairing name:** without a special entitlement iOS reports the device name as "iPhone", so the Mac listed "iPhone". The pairing sheet's name field (task 5.3) is the way to set "Sam's iPhone".
- **Launching the Debug Mac app:** run it with `open -n --env FUNES_DATA_DIR=… FunesVault.app --args --dev-seed`. Started as a background child of a shell, it exits with that shell.

### Before the run (2026-10-20): partly covered in software
Phase 0 deferred this spike "until just before Phase 5", and Phase 5 depends on it passing.

- **Covered by task 5.1** (`swift test --package-path Packages/FunesProtocol`, on macOS 15 CryptoKit):
  - HPKE `P256_SHA256_AES_GCM_256` seal and open, and `exportSecret` for the response key, work as the protocol needs. The fallback (a second HPKE seal to the device) isn't needed.
  - Row **1f** in software: tampered `ct`, `enc`, `sig`, `nonce` or `ts`, replayed nonces and skewed clocks are each refused with their code. Fuzzing the envelope, response, pairing and method decoders (3,000 seeded mutations each) finds no crash and nothing that opens to other bytes.
  - The pairing exchange (§2) end to end in one process, including a wrong secret, another Mac's key, and an answer for a different request.
- **Proposal:** instead of a throwaway pair of apps, run the matrix against the real companion server (task 5.2) and the first iPhone build (task 5.3), before 5.4 starts. The CloudKit doorbell test (Q24) needs the same iPhone, so both can be done in one sitting.
- **Covered by task 5.3** (`swift test --package-path Packages/FunesCompanion`, `PhoneClientTests`): the iPhone's own `CompanionClient` pairs with the real router and pairing service, calls `status.get` and `captures.submit` (a resent `captureId` is accepted once), runs the 1f checks, and sees a Deny and a revoke for what they are. `FunesPhone`'s tests cover address selection, the 3 s probe, the 10-minute cache, the `clock_skew` retry and resending after a lost answer.
- **Ready to run on the device (2026-10-21):** a Debug build of the iPhone app (task 5.3) against a Debug Mac build. It times pairing (1a); in Debug, **Send a Test Capture** and **Send It Again** cover 1b and the duplicate half of 1c, and **Run Protocol Checks** sends a good envelope, the same one again, a tampered ciphertext and a clock 5 minutes behind (1f). 1e and 1g need only the build. Rows 1d and 1h need the capture queue and background delivery of task 5.4.

---

## Spike 2: Search quality and speed

**Run:** 16 Oct 2026 on an M1 MacBook (8 cores, 8 GB), macOS 27.0.1, Xcode 27.0 toolchain (Swift 6.4).
**Code:** throwaway benchmark in [`spikes/search/`](../../spikes/search/) (`swift run -c release search-spike`); full output in [`run-1.md`](../../spikes/search/run-1.md) (quiet machine; stopped at the re-rank step, see below) and [`run-2.md`](../../spikes/search/run-2.md) (complete, with the re-rank, but run while the Mac was busy with other work). Quality numbers are identical in both runs; timings below come from run 1.
**Fixtures (permanent):** [`memories-200.json`](../../Packages/FunesCore/Tests/FunesCoreTests/fixtures/memories-200.json) and [`queries-30.json`](../../Packages/FunesCore/Tests/FunesCoreTests/fixtures/queries-30.json) in `Packages/FunesCore/Tests/FunesCoreTests/fixtures/`. They're synthetic: one invented freelancer's preferences, projects, health, finances and legal matters, across all 8 built-in categories, with deliberate overlaps (coffee as a preference and as a caffeine limit, Harbor as a project, a GDPR question and a Slack style, and so on). The 30 queries are agent-style tasks ("Plan a week of dinners for me"), each labelled with 1–3 relevant memory ids. `SearchFixtureTests` keeps both files well-formed.

### Verdict: **fail** on quality, pass on speed

| Criterion | Target | Best measured | Result |
|---|---|---|---|
| Hybrid recall@5 (200 memories) | ≥ 0.85 | **0.583** (`NLContextualEmbedding` + FTS5 porter, 0.45/0.55); **0.744** with Foundation Models query expansion; re-ranking with Foundation Models doesn't raise it | ❌ |
| Query latency at 10,000 memories | < 150 ms | **18 ms p50, 22 ms p95** (centered contextual + FTS5 porter, full path); 3.7 s more with expansion | ✅ (❌ with expansion) |

Apple's on-device embeddings are fast but too weak for this job. The queries they miss need a step of inference that the models don't make: "plan dinners" → *vegetarian* and *peanut allergy*, "the doctor wants to prescribe antibiotics" → *penicillin allergy* (rank 78), "where should I deploy the server" → *Hetzner VPS* (rank 90). The per-query dump at the end of `run-2.md` has every case. Keyword search alone (FTS5 with stemming) is about as good as any hybrid with these models.

### What was compared

- **Keyword:** FTS5 BM25 through GRDB 7.11.1, external-content table and trigger as in [storage](../architecture/storage.md). The task text becomes an OR query of its non-stopword terms; BM25 is normalized by the best score. Two tokenizers: the spec's `unicode61 remove_diacritics 2`, and `porter unicode61 remove_diacritics 2` (English stemming).
- **Semantic:** `NLEmbedding.sentenceEmbedding(for: .english)` and `NLContextualEmbedding(language: .english)` with token vectors mean-pooled, both L2-normalized, over the spec's embedding input `title \n kind \n category names \n body`. Each also **mean-centered**: subtract the mean vector of the 200 fixture memories, then re-normalize.
- **Hybrid:** `wk × keyword + ws × max(0, cosine)` at 0.45/0.55 and 0.3/0.7, plus a sweep from 0/1 to 1/0.
- **Fallback (from the spike plan):** Foundation Models (on-device, greedy) expands the task into 8–15 keywords, which are appended to the query for both the keyword and the semantic side; and Foundation Models re-ranks the top 30.
- **Not run:** Ollama `nomic-embed-text` (no Ollama on this Mac) and OpenAI `text-embedding-3-small` (no API key here). Vector dimensions on iOS weren't measured (no device run).

### Models

| Model | Dims (macOS) | Embed per memory | Embed per query | Notes |
|---|---|---|---|---|
| `NLEmbedding` sentence (en), revision 1 | 512 | 9.5 ms (12.7 ms over 10K) | 4.7 ms | Weakest at everything |
| `NLContextualEmbedding` (en), model `5C45D94E-…`, revision 1 | 512 (not 768) | 14.5 ms (15.4 ms over 10K) | 12.0 ms | Max 256 tokens. Raw cosines are squeezed into 0.82–0.94 for *every* pair (anisotropy) |

Re-embedding 10,000 memories with the contextual model takes about 2.5 minutes on an M1. 10,000 × 512 Float32 is 19.5 MB.

### Quality (200 memories, 30 queries)

Recall@5 is the share of a query's relevant memories found in the top 5, averaged; MRR is the mean reciprocal rank of the first relevant one.

| Method | R@5 | R@10 | MRR | R@5 expanded | MRR expanded |
|---|---|---|---|---|---|
| FTS5 `unicode61` (spec) | 0.456 | 0.528 | 0.587 | 0.533 | 0.778 |
| FTS5 `porter unicode61` | 0.567 | 0.606 | 0.714 | 0.667 | 0.841 |
| `NLEmbedding` sentence | 0.250 | 0.306 | 0.375 | 0.322 | 0.357 |
| `NLContextualEmbedding` | 0.411 | 0.533 | 0.500 | 0.517 | 0.709 |
| `NLContextualEmbedding` centered | 0.389 | 0.483 | 0.459 | 0.600 | 0.727 |
| sentence + FTS5 porter, 0.45/0.55 | 0.522 | 0.672 | 0.729 | 0.667 | 0.834 |
| contextual + FTS5 porter, 0.45/0.55 | **0.583** | 0.628 | 0.761 | 0.667 | 0.846 |
| contextual + FTS5 porter, 0.3/0.7 | **0.583** | 0.628 | 0.757 | 0.644 | 0.831 |
| contextual centered + FTS5 porter, 0.45/0.55 | 0.567 | 0.656 | 0.789 | 0.739 | 0.871 |
| contextual centered + FTS5 porter, 0.3/0.7 | 0.533 | 0.683 | 0.774 | **0.744** | **0.883** |
| contextual centered + FTS5 `unicode61`, 0.45/0.55 | 0.439 | 0.550 | 0.643 | 0.683 | 0.831 |

With 30 queries and 70 relevant labels, one memory moving in or out of a top 5 changes R@5 by about 0.01–0.03, so differences under ~0.05 are noise.

**Foundation Models re-rank of the top 30** (centered contextual + FTS5 porter, 0.3/0.7 pool; the model returns up to 10 note numbers, most useful first):

| Pool | Recall@30 of the pool | R@5 before → after | MRR before → after | Time per query p50 / p95 |
|---|---|---|---|---|
| original queries | 0.828 | 0.533 → 0.611 | 0.774 → 0.865 | 8.4 s / 18.0 s |
| expanded queries | 0.933 | 0.744 → 0.700 | 0.883 → 0.936 | 9.1 s / 15.2 s |

Re-ranking puts the single most useful memory first more often (MRR 0.94), but it picks too few of the others, so recall@5 doesn't improve, and it costs 8–9 s more per query (times from run 2, on a busy machine).

**At 10,000 memories** (6,791 paraphrased copies and 3,009 mixtures of sentences from 2–3 fixture memories; a paraphrase counts as its source), R@5 falls to 0.28–0.36 without expansion and 0.37–0.43 with it. This number is pessimistic: the mixtures contain sentences of the relevant memories but count as misses. It's informational only; the pass criterion uses the 200-memory quality and the 10,000-memory latency.

### Weights
The sweep is flat. For centered contextual + FTS5 porter, R@5 stays at 0.55–0.58 (MRR 0.75–0.79) from 0.35/0.65 to 0.70/0.30 on the original queries, and 0.73–0.76 from 0.20/0.80 to 0.45/0.55 on expanded queries. **0.45/0.55 is confirmed**; 0.3/0.7 is no better. Nothing in this data argues for changing the weights while the embedding model is this weak.

### Thresholds
Cosine of each query with its relevant memories vs all others (200 memories):

| Model | Relevant: p10 / median | Others: median / p90 / p99 |
|---|---|---|
| sentence | 0.19 / 0.34 | 0.22 / 0.38 / 0.50 |
| contextual (raw) | 0.84 / 0.89 | 0.85 / 0.89 / 0.92 |
| contextual centered | 0.09 / 0.29 | −0.01 / 0.20 / 0.38 |

- **Raw contextual vectors make 0.30 and 0.35 meaningless:** every memory scores ≥ 0.82, so both thresholds keep the whole vault. A threshold only works on centered vectors.
- **Centered contextual, keep if keyword > 0 or semantic ≥ T** (200 memories, original queries, FTS5 porter):

| T | Vault: recall of all kept / mean kept | Retrieval: recall@30 (0.45/0.55) |
|---|---|---|
| 0.15 | 0.933 / 43.9 | 0.850 |
| 0.20 | 0.861 / 33.5 | 0.850 |
| 0.25 | 0.806 / 27.3 | 0.794 |
| 0.30 | 0.794 / 23.2 | 0.783 |
| 0.35 | 0.783 / 20.6 | 0.783 |
| keyword only | 0.706 / 18.3 | — |

- **Changed:** for `apple.nl/contextual-en` (centered), **vault 0.30 → 0.20** (recall 0.79 → 0.86 for ten more results per query, and the vault list is the user's own view) and **retrieval 0.35 → 0.25** (recall@30 0.78 → 0.79, still stricter than the vault; going lower adds candidates for the approval panel, and for auto-allowed agents, with little recall gain). Both are provisional until the default model is settled (below).
- **Keyword > 0 dominates what gets kept.** An OR query over the task's terms matches about 9% of the vault (18 of 200 per query) before any semantic threshold applies, so at 10,000 memories it would be ~900. Retrieval needs a keyword floor too (for example normalized BM25 ≥ 0.2) or an AND-leaning query; Phase 1 task 1.4 should measure it with this benchmark.

### Latency (10,000 memories, full query path, 30 queries × 5 runs)
Embed the query, FTS5, dot product (`vDSP_mmul` over 10,000 × 512), combine, filter, top 30:

| Path | Embed | FTS5 | Dot | Rank | Total p50 | p95 |
|---|---|---|---|---|---|---|
| FTS5 porter only | — | 1.8 | — | 0.9 | 2.6 | 5.2 |
| sentence + FTS5 porter (T 0.35) | 4.8 | 2.1 | 0.8 | 2.6 | 10.4 | 16.9 |
| contextual + FTS5 porter (raw, T 0.35 keeps everything) | 11.1 | 2.1 | 0.9 | 10.7 | 24.7 | 27.6 |
| contextual centered + FTS5 porter (T 0.20) | 12.0 | 2.3 | 0.9 | 2.7 | **18.0** | **22.0** |
| same, expanded query text | 14.4 | 4.8 | 0.9 | 3.9 | 24.2 | 29.2 |
| Foundation Models expansion (per query, extra) | | | | | 3,735 | 4,364 |

At 200 memories every path's p50 is under 16 ms. Run 2, on a busy machine, measured 20.2 ms p50 and 24.9 ms p95 for the centered contextual path at 10,000. Brute force is fine at this scale; no ANN index needed.

### Foundation Models findings
- **Expansion works, slowly:** +0.10 to +0.20 R@5 for every method, at 3.7 s p50 per query on an M1. That rules it out for as-you-type vault search; it is tolerable for agent retrieval, which already waits for approval (Spike 3), and could be cached per task hash for the 15-minute request window.
- **Guardrails refuse vault content.** With the default guardrails, at least one re-rank prompt containing health and finance notes failed with "May contain sensitive content". Any Foundation Models step over memory text must catch refusals and fall back, and may need `SystemLanguageModel(guardrails: .permissiveContentTransformations)`, which only allows plain-text output. Run 1 crashed on such a refusal in the re-rank step. Run 2, with the retry, needed the permissive model for 1 of 60 re-rank prompts and had no final refusals. Expansion prompts (task text only) were never refused.

### Outputs (as the spike plan asks)

| Output | Result |
|---|---|
| **Chosen model** | `NLContextualEmbedding` (en), mean-pooled and **mean-centered**, as the on-device default, because it's the best Apple option. It doesn't meet the bar, so it's a stopgap and the default needs a decision (below). `NLEmbedding` sentence is rejected. |
| **Weights** | 0.45 keyword / 0.55 semantic, **confirmed**. |
| **Vault threshold** | 0.30 → **0.20** for centered contextual (raw contextual can't use a threshold). |
| **Retrieval threshold** | 0.35 → **0.25** for centered contextual; add a keyword floor (see above). |
| **Keyword tokenizer** | **Change** to `porter unicode61 remove_diacritics 2`: +0.11 R@5 on its own, +0.13 inside the best hybrid. |
| **Recorded constants + regression test** | Fixtures committed now with a well-formedness test. Phase 1 task 1.4 turns them into the recall regression with baselines: FTS5 porter R@5 ≥ 0.56, centered contextual + FTS5 porter (0.45/0.55) R@5 ≥ 0.56 and MRR ≥ 0.78 (re-measure inside FunesCore before freezing). |

### Spec changes the spike proposed
Written before the decision below. With keyword-only search, only the tokenizer change applies now; the embedding items apply if Apple's embeddings are ever revisited:
1. [memory-processing §2–4](../domain/memory-processing.md#2-embeddings-and-semantic-search) and [storage](../architecture/storage.md): the porter tokenizer; mean-centering as part of the Apple embedder (store the 512-float mean per `model_id`, computed once from the bundled fixture memories so it doesn't drift with the vault); thresholds 0.20 / 0.25 for that model id; a keyword floor for retrieval.
2. [access policy §3.2](../domain/access-policy.md#32-retrieval-which-memories-are-relevant): the retrieval threshold, and the keyword floor.
3. [model providers](../architecture/model-providers.md): Apple's embedding row names `NLContextualEmbedding` (centered); 512 dims, not 768.

### Decision needed: how to reach recall@5 ≥ 0.85
With the spike plan's fallback, the Apple-only stack gets to 0.74 with expansion (3.7 s per query), and re-ranking adds nothing to recall for another 8–9 s. Options:
1. **A small open embedding model bundled as Core ML** (for example bge-small-en-v1.5 or e5-small-v2: MIT licence, 384 dims, about 33M parameters, roughly 65–130 MB; expected to take a few ms per query, which is unmeasured here). The roadmap already lists local open-source embeddings as an upgrade path; this would pull it into v0.1. Needs: your OK to bundle a model asset (it's not a Swift package, but it's a third-party dependency), and a short **Spike 2b** with this same benchmark.
2. **Ship with Apple's model, and make a stronger provider easy:** Ollama `nomic-embed-text` or a cloud model through the existing model-provider design, re-running this benchmark for their thresholds (Spike 2b can do both with synthetic data once Ollama is installed and a key is available).
3. **Accept ~0.58 keyword-led search for v0.1**, with Foundation Models expansion for agent retrieval only (0.74, +3.7 s), and revisit after launch. Skip the re-rank.

Recommendation: **1, then 2.** On these fixtures the weakness is the embedding, not the ranking formula, and a small modern embedding model is the cheapest fix that keeps everything on the Mac and under 150 ms.

### Decision (2026-10-16; superseded by Spike 2b, see below)
**Keyword search for v0.1; semantic search later as an opt-in** ([ADR-0015](../architecture/decisions/0015-keyword-search-first.md)). This is close to option 3, without Foundation Models expansion.
- **v0.1 search:** FTS5 BM25 with the `porter unicode61 remove_diacritics 2` tokenizer, for both vault search and agent retrieval. There are no embeddings, so `semantic` is 0.
- **Regression baseline:** FTS5 porter recall@5 ≥ 0.56 on these fixtures (Phase 1 task 1.4).
- **Later:** an Embeddings row in Settings ▸ AI Models, off by default. It offers a local server, a cloud model, or a bundled open model; the bundled option (1 above) needs a Spike 2b first. Any option must beat the keyword baseline. Foundation Models query expansion for agent retrieval is on the roadmap as a separate later option.

---

## Spike 2b: Local open-source embeddings

**Run:** 17 Oct 2026, same M1 (8 GB), macOS 27.0.1. **Question:** does a local open embedding model clear recall@5 ≥ 0.85 with < 150 ms at 10,000 memories, and does agent-side query expansion help?
**Code:** [`spikes/embeddings/`](../../spikes/embeddings/README.md) (Python: embeddings, Core ML conversion) and `MODE=2b` / `MODE=coreml` in [`spikes/search/`](../../spikes/search/) (Swift: FTS5, scoring, latency, Core ML end to end). Full output: [`spikes/embeddings/run-2b.md`](../../spikes/embeddings/run-2b.md).
**Fixtures:** Spike 2's `memories-200.json` and `queries-30.json`, plus a new permanent [`queries-30-expanded.json`](../../Packages/FunesCore/Tests/FunesCoreTests/fixtures/queries-30-expanded.json): each task with 5–15 keywords and 1–3 category keys, as an agent would add them to `request_memory`. A spike-only `queries-30-es.json` holds Spanish translations of the 30 tasks.

### Verdict

| Query text | Bar: R@5 ≥ 0.85, < 150 ms at 10K | Best result |
|---|---|---|
| **Raw task** (as in Spike 2) | ❌ **fail**, all models | 0.78: nomic-embed-text v1.5 + FTS5 (0.05/0.95); bge-small alone 0.77 |
| **Agent-expanded** (task + keywords) | ✅ **pass** | **bge-small-en-v1.5 via Core ML: R@5 0.94, MRR 0.97, 10.5 ms p50 end to end at 10,000** (hybrid, min-max 0.30/0.70). nomic, multilingual-e5-small and Qwen3 also reach 0.94–0.96 |

Open models are much better than Apple's on raw tasks (0.56–0.77 alone vs 0.39), but the misses that need inference remain. With raw tasks, bge-small alone still ranks *peanut allergy* 196th for "plan dinners". What closes the gap is the agent saying what context it wants. With the expanded text, **keyword search alone reaches 0.83**, Apple's contextual embedding hybrid 0.87–0.89, and the open models 0.92–0.96.

### Models (all local)

| Model | Licence | Dims | Weights | R@5 raw (alone / best hybrid) | R@5 agent (alone / min-max 0.30/0.70) | R@5 Spanish (alone) | Query embed p50 (runtime) |
|---|---|---|---|---|---|---|---|
| FTS5 porter (keyword only) | — | — | — | 0.567 | 0.828 | 0.189 | — |
| Apple `NLContextualEmbedding`, centered (Spike 2) | OS | 512 | in OS | 0.389 / 0.583 | 0.689 / 0.872 | 0.339 | 11.9 ms (Swift) |
| **bge-small-en-v1.5** | MIT | 384 | 127 MB fp32; **64 MB Core ML fp16** | **0.767** / 0.767 | 0.894 / **0.939** | 0.400 | 16.5 ms (PyTorch MPS); **3.6 ms (Core ML CPU, Swift)** |
| e5-small-v2 | MIT | 384 | 127 MB | 0.717 / 0.717 | 0.872 / 0.922 | 0.350 | 15.7 ms (MPS) |
| multilingual-e5-small | MIT | 384 | 449 MB | 0.561 / 0.617 | 0.856 / 0.939 | **0.539** | 15.9 ms (MPS) |
| nomic-embed-text v1.5 | Apache-2.0 | 768 | 522 MB | 0.722 / **0.778** | 0.883 / 0.944 | 0.339 | 24.4 ms (MPS) |
| Qwen3-Embedding-0.6B | Apache-2.0 | 1024 | 1,136 MB | 0.722 / 0.739 | 0.911 / 0.933 | **0.644** | 86.0 ms (MPS, fp16) |
| EmbeddingGemma-300m | Gemma Terms of Use | 768 | — | **not run**: gated. With a signed-in read token, Hugging Face still returns 403 because the Gemma terms aren't accepted on that account. No unofficial mirror was used | | | |

Notes:
- **Prefixes, as each model documents:** bge uses the retrieval instruction for queries (without it: 0.761 raw, 0.956 best agent; same within noise); e5 `query:`/`passage:`; nomic `search_query:`/`search_document:`; Qwen3 a task instruction ("Given a task that an AI assistant received, retrieve the user's personal notes that help with the task"). The document text is the spec's `title \n kind \n categories \n body`, truncated to 256 tokens.
- **Runtimes:** quality numbers come from PyTorch 2.14.1 on MPS (fp32, Qwen3 fp16) through sentence-transformers 6.1.0, except the Core ML row. nomic's remote code needed a one-method shim for transformers 5.x.
- **Embed time per memory** (batch 32, MPS): 2.2–2.5 ms for the small models, 11 ms nomic, 55 ms Qwen3. Core ML CPU from Swift, one at a time: 4.7 ms, so re-embedding 10,000 memories takes about 47 s.
- **To add EmbeddingGemma later:** accept the terms at huggingface.co/google/embeddinggemma-300m with the signed-in account, then run `embed.py corpus.json vectors embeddinggemma` and rescore with `MODE=2b` (see the spike README). Its prompts (`task: search result | query: `, `title: none | text: `) are already in `embed.py`.
- With 30 queries and 70 labels, differences under ~0.05 are noise. The three small English models and nomic are effectively tied on agent queries.

### Fusion: the spec's formula needs a change
`0.45 × keyword + 0.55 × cosine` assumes cosines spread over [0, 1]. Modern models compress them: bge's unrelated memories score 0.45 median (relevant 0.64), e5's 0.76 (relevant 0.83). So the max-normalized keyword term dominates, and the hybrid is *worse* than the embedding alone on raw tasks (bge: 0.59 vs 0.77). Normalizing the cosine per query (min-max over the vault) fixes most of it:

| bge-small (Core ML) | R@5 raw | R@5 agent | R@5 agent, 10K |
|---|---|---|---|
| embedding alone | 0.767 | 0.894 | 0.839 |
| linear 0.45/0.55 (spec) | 0.594 | 0.878 | 0.817 |
| linear 0.30/0.70 | 0.617 | 0.900 | 0.800 |
| **min-max 0.30/0.70** | 0.689 | **0.939** | 0.800 |
| reciprocal rank fusion | 0.622 | 0.883 | 0.811 |

Min-max 0.30/0.70 is the best or tied for best for every open model on agent queries, and it doesn't need per-model weights. (The 10,000 column counts a paraphrase as its source, and a mixture as a hit when it contains a sentence of a relevant memory.)

### Thresholds (bge-small, raw cosine; keep if keyword > 0 or cosine ≥ T)

| T | Vault: recall / kept per query (raw tasks) | Retrieval R@30 (raw tasks) | Retrieval R@30 (agent) |
|---|---|---|---|
| 0.45 | 0.978 / 99 | 0.911 | 0.978 |
| **0.50** | **0.944 / 53** | 0.911 | 0.978 |
| **0.55** | 0.894 / 28 | **0.878** | **0.978** |
| 0.60 | 0.822 / 20 | 0.806 | 0.978 |

The cosine distribution: relevant p10 0.50, median 0.64; others median 0.45, p90 0.54, p99 0.61. Proposed for `bge-small-en-v1.5`: **vault 0.50, retrieval 0.55**. The thresholds filter on the raw cosine, while ranking uses the min-max score. With agent keywords, `keyword > 0` alone keeps 34 memories per query (17% of the vault), so the keyword floor from Spike 2 matters more, not less.

### Latency at 10,000 memories (Swift, 30 agent queries × 5 runs)
Search without the query embedding (FTS5 porter + `vDSP_mmul` over 10,000 × 384 + fusion + top 30) is **6.9 ms p50, 10.7 ms p95**. End to end:

| Path | Query embedding | Total p50 |
|---|---|---|
| **bge-small, Core ML fp16, CPU only, Swift (incl. WordPiece)** | **3.6 ms** (p95 6.0) | **10.5 ms** |
| bge-small / e5 / multilingual-e5, PyTorch MPS | 16 ms | 22–23 ms |
| nomic v1.5, PyTorch MPS | 24 ms | 32 ms |
| Qwen3-0.6B, PyTorch MPS fp16 | 86 ms | 94 ms |

Every model passes < 150 ms. **Core ML compute units matter:** for this small model, CPU only (3.6 ms per query, 4.7 ms per memory, 0.3 s load) beats the Neural Engine (16 ms, 19.5 ms, 2.6 s load), the GPU (9 ms, 95 ms p95), and `.all` (9 ms, 148 ms p95, 7.4 s load). The enumerated sequence lengths (16–256 tokens) make the accelerators re-specialize between shapes. The Core ML model (with pooling and L2 normalization inside) matches PyTorch to cosine 1.0000, and gives identical R@5. The Swift WordPiece tokenizer (about 100 lines, no dependency) matched Hugging Face's ids on 2,090 of 2,090 texts.

### Agent-side query expansion
The agent writes the expansion from the task alone, for example "Plan a week of dinners" + *diet, dietary restrictions, food allergies, food preferences, favourite cuisines, cooking, recipes, meal planning, nutrition, grocery budget* + `personal_preferences, health`.

| | Raw task | + keywords | + keywords + category filter |
|---|---|---|---|
| FTS5 porter alone | 0.567 | **0.828** | 0.878 |
| bge-small hybrid (min-max 0.30/0.70) | 0.689 | **0.939** | 0.939 |
| Spike 2's Foundation Models expansion, FTS5 alone | — | 0.667 (3.7 s) | — |

- **A `keywords` hint is worth adding** to `request_memory`: an optional array of 5–15 terms naming the kinds of personal context that would help ("dietary restrictions, allergies"). It's the biggest single gain measured in Spikes 2 and 2b (+0.26 for keyword search). It costs the agent nothing, and it works with or without embeddings.
- **`categories` (already a narrowing filter):** +0.05 for keyword-only, nothing for the hybrid. It's also risky: a wrong guess hides the right memory. Keep it as specified and don't push agents to use it.
- **Caveat:** I wrote the expansions knowing the vault, while trying not to use it. The keyword-only 0.83 may be optimistic. The Foundation Models expansions from Spike 2 (3B model, blind to the vault) got 0.67. Measure with real agents' `keywords` before relying on the number.

### Multilingual (for the planned Spanish version)
Measured: **Spanish tasks against English memories** (cross-lingual). English-only models fall to 0.34–0.40; multilingual-e5-small gets 0.54–0.57 and Qwen3 0.64–0.66. FTS5 gets 0.19. Not measured: Spanish memories with Spanish tasks, which is the real case for a Spanish-speaking user. multilingual-e5-small is the only small multilingual candidate. It ties bge on agent queries (0.939) but is weaker on raw tasks (0.56 vs 0.77). It's 3.5× the size (≈ 235 MB as Core ML fp16, estimated from 118M parameters, most of them in the 250K-token vocabulary), and it needs a SentencePiece (Unigram) tokenizer in Swift instead of WordPiece. **Not worth it for v0.1**; decide when the Spanish version is scoped, with a Spanish-memory benchmark.

### Recommendation
1. **Model: bge-small-en-v1.5**, **bundled as Core ML** (fp16 ML Program, pooling and normalization inside), run **CPU only**. It's the smallest and fastest candidate and ties the best on agent queries.
   - **App-size cost:** +64 MB (the `.mlpackage`; int8 weight quantization would roughly halve it, untested) and 30 KB of vocabulary.
   - **Licence:** MIT. Bundling needs the copyright and licence text in `NOTICE` and the app's acknowledgements.
   - **Speed:** 3.6 ms per query, 4.7 ms per memory, 10.5 ms per search end to end at 10,000 memories.
2. **Not MLX Swift:** it's a new package dependency and GPU-bound, and CPU Core ML is already fast enough. **Not Ollama** as the default: nomic-embed-text through Ollama is a reasonable *opt-in* alternative (Apache-2.0, 0.94 on agent queries) for users who run it already.
3. **Fusion:** `0.30 × keyword + 0.70 × semantic`, with `semantic` the cosine min-max normalized over the vault per query. Thresholds on the raw cosine: vault 0.50, retrieval 0.55 for this model id.
4. **Add `keywords` to `request_memory`**, and make the tool description ask for them. It lifts keyword-only v0.1 search to ~0.83 even if embeddings wait.
5. **Multilingual later:** multilingual-e5-small (MIT) is the candidate when Spanish ships, after a Spanish-memory benchmark. Qwen3-0.6B is better cross-lingually but 1.1 GB and 86 ms per query.
6. **Licences for bundling:** bge-small, e5 and multilingual-e5 are MIT; nomic and Qwen3 are Apache-2.0. All allow bundling with an attribution notice. EmbeddingGemma (unmeasured here) is under Google's **Gemma Terms of Use**, which isn't an open-source licence. Redistributing it means passing its use restrictions and Prohibited Use Policy on to users, with a notice in the app, and Google can update those terms. That's a heavier obligation for a bundled default than MIT or Apache-2.0, so it should only be chosen if it clearly wins once it's measured.

On these fixtures, "keyword-only plus agent keywords" (0.83) is a solid v0.1 baseline. "bge-small Core ML hybrid plus agent keywords" (0.94) is the version that clears the bar.

### Decision (2026-10-17)
**v0.1 ships bundled bge-small-en-v1.5 (Core ML, CPU), min-max 0.30/0.70 fusion, and an optional `keywords` field on `request_memory`** ([ADR-0016](../architecture/decisions/0016-bundled-bge-small-embeddings.md), superseding ADR-0015). The spec changes below were made with that ADR. Multilingual embeddings and other embedding models are later.

### Spec changes this implied (made with ADR-0016)
1. **[ADR-0015](../architecture/decisions/0015-keyword-search-first.md):** either keep v0.1 keyword-only and add `keywords`, or ship bundled bge-small Core ML by default (needs a new or amended ADR, and an update to AGENTS.md's dependency list, since it's a bundled third-party asset).
2. **[MCP server](../architecture/mcp-server.md) and [access policy §3.2](../domain/access-policy.md#32-retrieval-which-memories-are-relevant):** an optional `keywords: [string]` on `request_memory`, appended to the task text for retrieval (and, like the task, never stored); the hybrid formula with min-max semantic and 0.30/0.70.
3. **[Memory processing §2–4](../domain/memory-processing.md#2-embeddings-and-semantic-search):** the default model `bge-small-en-v1.5` (Core ML fp16, CPU, 384 dims, CLS pooling, the query instruction prefix, WordPiece); fusion; per-model thresholds 0.50 / 0.55; mean-centering only for Apple's model.
4. **[Storage](../architecture/storage.md):** the `embedding` table returns in schema v1 if embeddings ship in v0.1 (`model_id` e.g. `bge-small-en-v1.5/coreml-fp16`, 384 dims, 15 MB at 10,000).
5. **[Model providers](../architecture/model-providers.md):** a "Bundled (on this Mac)" embedding provider row; Ollama nomic-embed-text as the documented local-server option.
6. **[Testing strategy](testing-strategy.md) / Phase 1 task 1.4:** add `queries-30-expanded.json` to the regression. Baselines from this run: FTS5 porter + keywords R@5 ≥ 0.82; bge-small hybrid + keywords R@5 ≥ 0.92.
7. **`NOTICE`:** BAAI's MIT notice for the bundled model.

### Phase 1 re-measurement in FunesCore
**Run:** 2026-10-16, same M1, through `SearchService.retrieve` (FunesCore task 1.4) on the 200 fixture memories and 30 tasks, top 30. The test is `SearchBenchmarkTests`; `FUNES_SEARCH_SWEEP=1` prints the tables below.

| Path | R@5 | R@30 | MRR | Exit criterion (R@5) |
|---|---|---|---|---|
| hybrid (int8 model), task + keywords | **0.939** | 0.989 | 0.967 | ≥ 0.92 |
| hybrid (int8 model), raw task | **0.689** | 0.911 | 0.831 | ≥ 0.68 |
| keyword only, task + keywords | **0.828** | 0.978 | 0.896 | ≥ 0.82 |
| keyword only, raw task | 0.567 | 0.706 | 0.714 | — |

The Spike 2b numbers reproduce exactly with the fp16 model (0.939 / 0.689 / 0.828). The Swift WordPiece tokenizer matches Hugging Face's ids on all 268 fixture texts (memories, raw and expanded queries, and edge cases: accents, CJK, emoji, punctuation, odd whitespace, 400-word texts).

**Int8 weights** (coremltools `linear_quantize_weights`, linear symmetric): 32 MB instead of 64 MB; worst cosine against sentence-transformers' fp32 vectors 0.99956 (fp16: 0.99998); the same R@5 on both query sets (raw R@30 0.911 vs 0.894); 3.7 ms per query and 0.83 s for the 200 memories, the same as fp16. **Kept** as the bundled model, `bge-small-en-v1.5/coreml-int8` ([ADR-0016](../architecture/decisions/0016-bundled-bge-small-embeddings.md), Phase 1 update).

**Keyword floor sweep** (R@5 / R@30 / memories kept per query before the top-30 cut):

| Floor | hybrid, + keywords | hybrid, raw | keyword only, + keywords | keyword only, raw |
|---|---|---|---|---|
| 0 | 0.939 / 0.989 / 44.5 | 0.689 / 0.894 / 27.8 | 0.828 / 0.978 / 34.4 | 0.567 / 0.706 / 18.3 |
| 0.10 | 0.939 / 0.989 / 43.4 | 0.689 / 0.894 / 27.8 | 0.828 / 0.978 / 33.0 | 0.567 / 0.706 / 18.3 |
| **0.15** | 0.939 / 0.989 / **38.3** | 0.689 / 0.894 / 27.6 | 0.828 / 0.978 / **26.0** | 0.567 / 0.706 / 18.0 |
| 0.20 | 0.939 / 0.989 / 33.0 | 0.689 / 0.894 / 26.5 | 0.828 / 0.950 / 18.3 | 0.567 / 0.706 / 16.5 |
| 0.25 | 0.939 / 0.989 / 29.3 | 0.689 / 0.883 / 25.1 | 0.828 / 0.889 / 12.8 | 0.567 / 0.683 / 14.4 |
| 0.30 | 0.939 / 0.989 / 27.2 | 0.689 / 0.883 / 24.0 | 0.828 / 0.889 / 9.4 | 0.550 / 0.656 / 12.8 |
| 0.50 | 0.939 / 0.978 / 23.7 | 0.689 / 0.861 / 19.7 | 0.733 / 0.756 / 3.4 | 0.522 / 0.550 / 5.9 |

(fp16 model; int8 gives the same rows within ±0.02 R@30.) **Chosen: 0.15**, the highest floor with no loss in R@5 or R@30 on any path. Higher floors shrink the approval list further but start losing relevant memories from the top 30 in keyword-only mode, the fallback when the model can't load.

---

## Spike 3: Agent timeouts and the in-call approval
**Run:** 2026-10-16. **Code:** [`spikes/agent-timeouts/`](../../spikes/agent-timeouts/README.md), a throwaway stdio MCP server (Python standard library) plus a log reader.
**Status:** **pass.** Claude Code and Codex were measured headless. Claude Desktop and Cursor were checked by hand in the Phase 2 hands-on check (2026-10-17): both waited the full 45 s. Q10 is decided.

### What was measured
The server has three tools:
- `wait_seconds` sleeps N seconds.
- `request_memory` optionally waits in-call, then returns `needs_approval`, a `request_id`, and a `message`.
- `get_memory_request` returns `needs_approval` until a fake approval 60 s after creation, then delivers a memory with a canary word.

The server logs every message, every `notifications/cancelled` and every hang-up, so a client-side timeout shows up as a cancellation time.

Claude ran the two CLIs headless (`claude -p`, `codex exec`), in a clean environment and with per-run configs, so no global agent config was changed. The others need a GUI and are left for a manual run.

### Results
| Agent (version) | Max wait before timeout | Progress shown | Auto-retry | Calls `get_memory_request` on its own | Surfaces "waiting for your approval in Funes" |
|---|---|---|---|---|---|
| Claude Code 2.1.288 | **≥ 300 s** measured (15, 30, 45, 60, 120, 300 all completed). Docs: `MCP_TOOL_TIMEOUT` ≈ 28 h | Headless: no server message, just a generic 30 s heartbeat. Interactive: not checked | No | **Partly.** In 3 of 3 runs it said it would check back and started a background `sleep 60`. The headless process then exited, so the follow-up call is unverified | **Yes** (3/3) |
| Codex CLI 0.160.0 | **≥ 90 s** measured (30, 45, 60, 90) with no `tool_timeout_sec`. Docs say 60 s; source says 300 s | Headless: no | No | **Yes.** It used its built-in `sleep` tool for 50–55 s, polled, and got the canary text: 2 of 2 runs, including with the 45 s in-call wait | **Yes** (2/2) |
| Claude Desktop | **≥ 45 s**, checked by hand against Funes's real panel (Phase 2, 2026-10-17); the exact maximum wasn't measured. Issue threads report a fixed ~60 s | — | — | — | — |
| Cursor | **≥ 45 s**, checked by hand against Funes's real panel (Phase 2, 2026-10-17); the exact maximum wasn't measured. Staff: ~60 min in the IDE, a hardcoded 60 s in the CLI/ACP | — | — | — | — |
| VS Code Copilot | Manual. Source: no client-side timeout | — | — | — | — |
| Gemini CLI | Manual. Docs: 600 s per server | — | — | — | — |

The figures marked docs, source, issues or staff come from a desk check on 2026-10-16. Sources:
- **Claude Code:** [env vars](https://code.claude.com/docs/en/env-vars) and [MCP](https://code.claude.com/docs/en/mcp) docs.
- **Claude Desktop:** issues [#22542](https://github.com/anthropics/claude-code/issues/22542) and [#63379](https://github.com/anthropics/claude-code/issues/63379).
- **Cursor:** [forum thread](https://forum.cursor.com/t/agent-acp-mcp-tools-call-times-out-at-60s-with-no-way-to-configure-it/163925).
- **Codex:** [`rmcp_client.rs`](https://github.com/openai/codex/blob/main/codex-rs/codex-mcp/src/rmcp_client.rs).
- **VS Code:** [`mcpServerRequestHandler.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/mcp/common/mcpServerRequestHandler.ts).
- **Gemini CLI:** [`mcp-server.md`](https://github.com/google-gemini/gemini-cli/blob/main/docs/tools/mcp-server.md).

### Findings
1. **Nobody we measured times out at 45 s.** The tightest documented limit is Claude Desktop's reported ~60 s. A 45 s panel wait plus delivery fits under it, and the server's own 55 s "time to answer a call" limit ([mcp-server.md §9](../architecture/mcp-server.md#9-limits)) is already below 60 s.
2. **Progress notifications don't buy time.** Clients built on the MCP TypeScript SDK keep `resetTimeoutOnProgress` at its default `false`. Cursor staff confirmed Cursor doesn't reset; Gemini CLI and Codex don't reset either. Claude Code and Codex send a `progressToken` on every call anyway. Neither CLI showed the server's progress message headless. VS Code and Gemini CLI render progress, per their source. Sending "Waiting for your approval in Funes…" every 5 s during the in-call wait is cheap, but it's cosmetic only.
3. **The `needs_approval` message works when it's explicit.** The spike's message said: *Tell the user: "Waiting for your approval in Funes." Then call get_memory_request with request_id "…" in about a minute; it expires in 15 minutes.* Both agents repeated the sentence to the user every time, and both chose a ~1 min wait. Neither polled faster than the once-per-5-s limit.
4. **Agents improvise a timer.** Claude Code backgrounds a `sleep 60`, and Codex has a built-in `sleep`. With an unrelated "wait" tool visible, Claude Code tried to use that tool as its timer. Funes should not expose anything that looks like a wait tool.
5. **No automatic retries** of a `tools/call` in either CLI. A timed-out `request_memory` would not be re-sent behind the user's back. This matches the docs for the others.
6. **Client identification:** `clientInfo.name` is `claude-code` (protocol `2025-11-25`) and `codex-mcp-client` (protocol `2025-06-18`). That's enough to key a per-agent-kind wait later, if one is ever needed.
7. **Side note:** both CLIs advertise the `elicitation` capability (form and url). It isn't a substitute for the Funes panel: the user must see the exact text in Funes. Still, it's worth knowing for "open Funes" nudges.

### Caveats
- Transport: the spike used stdio. Funes serves Streamable HTTP, with stdio only through the `funes-mcp` launcher. Claude Code applies a 5 min idle timeout to network servers, which is well above 45 s. The Phase 2 Python harness should re-check a 45 s call over HTTP for Claude Code and Codex.
- Headless runs can't show UI progress or a follow-up turn that a background timer triggers. The interactive checks are in the README checklist (`claude_tui.sh approval` covers Claude Code).
- Versions move fast. Re-run the spike before the v0.1 live matrix (Phase 4).

### Recommendation for Q10
**45 s for all agents** (the current default). No per-agent-kind table in v0.1, and no immediate return. Supporting changes for Phase 2:
- Use the explicit message wording from finding 3 in `request_memory` and `get_memory_request` ([mcp-server.md §6.2](../architecture/mcp-server.md#62-request_memory)).
- Send `notifications/progress` with "Waiting for your approval in Funes…" during the in-call wait, when the client sent a `progressToken`. Don't rely on it to extend timeouts. *(Deferred past v0.1: it needs an SSE response, which BridgeKitCore 0.1.0 doesn't send. See [mcp-server.md §1](../architecture/mcp-server.md#1-transport).)*
- Keep the in-call wait one constant. Log `clientInfo.name` with each request so a per-kind override can be added if a manual row comes in below ~50 s.
- Document per-agent behaviour in `docs/MCP.md` (Phase 4), from the completed table.

Fallback, unchanged from the plan: if Claude Desktop or Cursor turns out to cut off before ~50 s, make the wait per agent kind (for example 20 s for that client). If several do, return `needs_approval` immediately. Both measured agents handled the immediate-return path well.

**Q10 closed (2026-10-17):** Claude Desktop and Cursor waited the full 45 s, and Claude Code answered the real panel interactively, in the Phase 2 hands-on check. [Q10](open-questions.md) is decided: 45 s for all agents.

## Q24: CloudKit doorbell delivery time

**Question:** how long does a CloudKit "doorbell" take from the Mac to a **locked** iPhone, and can the phone's notification service extension reach the Mac while locked? It decides [Q24](open-questions.md) and [ADR-0019](../architecture/decisions/0019-cloudkit-doorbell-for-iphone-approvals.md), against the 45 s in-call wait ([Q10](open-questions.md)).

**Spike:** [`spikes/cloudkit-doorbell`](../../spikes/cloudkit-doorbell/README.md): a Mac app that saves `Doorbell` records to the private database and times each ring on its own clock until the phone's extension acknowledges it, and an iPhone app with the extension. Both build unsigned (`xcodebuild … CODE_SIGNING_ALLOWED=NO`); running them needs the portal steps in its README and the maintainer's iPhone.

**Pass:** run A (locked, Wi-Fi) delivers 20 of 20, with p90 ≤ 15 s and max ≤ 45 s, and run B (app swiped away) still delivers.

### Verdict (2026-10-20): **pass**, by a wide margin
CloudKit delivers the doorbell to a locked iPhone in about a second, and the locked phone's notification service extension reaches the Mac over the LAN. That's far inside the 45 s in-call wait, so **Q24 is decided: CloudKit**, and ADR-0019 is accepted.

**Set-up:** maintainer's iPhone 13 mini (iOS 27.0.1) on home Wi-Fi, charging; MacBook Air (macOS 27.0.1) on the same Wi-Fi. Both signed in to the same Apple Account. CloudKit Development environment, Apple Development signing (sandbox APNs). Times are from the start of the Mac's CloudKit save until the extension's acknowledgement arrived back at the Mac, all on the Mac's clock.

| Run | Phone | Rings | Delivered | Median | p90 | Max | Extension reached the Mac |
|---|---|---|---|---|---|---|---|
| Check | Unlocked, app open | 1 | 1 | 1.5 s | | | yes |
| A | Locked, Wi-Fi, every 90 s | 20 | 20 | 1.2 s | 1.5 s | 1.7 s | 20 of 20 |
| B | App swiped away, then locked, every 30 s | 10 | 10 | about 1 s (0.7–1.4 s where visible) | | ≤ 1.7 s | 10 of 10 |
| All | | 31 | **31** | **1.1 s** | **1.5 s** | **1.7 s** | 31 of 31 |

- **The CloudKit save** itself took 0.4–1.0 s of each time; the push and the extension's start added under a second.
- **The phone's clock agrees:** extension start minus the Mac's `sentAt`, median 1.0 s, max 1.5 s.
- **The extension ran every time**, also after the app was swiped away, and its plain HTTP request to the Mac's LAN address worked while locked. So 5.6 can fetch the panel's details over the companion channel from the extension.
- **Not run:** C (cellular plus Tailscale) and D (a Focus mode, and whether the Time Sensitive level gets through). Both are rows of the 5.8 manual matrix. If C shows the extension can't reach the Mac off Wi-Fi, the notification still arrives, worded "Open Funes to answer"; only the reworded text depends on reaching the Mac.
- **Caveat:** one evening, one phone and one network, on the development push environment. Production APNs is usually as fast or faster; 5.8 re-checks with a TestFlight build.

---|---|---|---|---|---|---|
| A | Locked, Wi-Fi | | | | | |
| B | App swiped away, locked | | | | | |
| C | Cellular + Tailscale, locked | | | | | |
| D | Focus on (Time Sensitive?) | | | | | |

---

## Phase 0 quick check: EK Bridge's `swiftc` build linking a Swift package
**Run:** 2026-10-16, Xcode 27.0 (Swift 6.4), macOS 27, M-series Mac. **Status:** **pass**, so ADR-0013 stands; no Xcode project for EK Bridge.

- A toy package (`library` product, an actor, Foundation) built with `swift build -c release --arch arm64 --arch x86_64` gives a universal `libToyKit.a` and `ToyKit.swiftmodule` (both slices) in `.build/out/Products/Release`.
- `swiftc -target <arch>-apple-macosx14.0 -I <dir> -L <dir> -lToyKit` linked it into a command-line tool per architecture; `lipo -create` made it universal; `codesign --options runtime` with the Developer ID identity signed it and `codesign --verify --strict` passed. `minos` stayed 14.0.
- Then for real (Phase 2 task 2.5): EK Bridge's `build.sh` links `BridgeKitCore` into the app, `bridge-mcp` and `bridge-client`, universal and signed, and `scripts/check_bundle.sh` passes.
- **Two traps, both handled in BridgeKit and `scripts/bridgekit.sh`:**
  - Xcode 26's SwiftPM (the native build system) makes no `.a` for an automatic library product when building one architecture, and keeps modules in `Modules/`. BridgeKitCore's product is declared `.static`, and the script picks the module folder.
  - In Swift 6 language mode, `MainActor.assumeIsolated` traps when a host drains the main queue with `dispatchMain()` (off the main thread). BridgeKitCore hops with `Task { @MainActor in … }`; test servers run the main run loop.

## Phase 2 live check: agents on the real MCP server
**Run:** 2026-10-17, Debug build, a development vault (`FUNES_DATA_DIR`, `--dev-seed`), Claude Code 2.1.288 and Codex CLI headless with per-run configs (no global config changed).

| Check | How | Result |
|---|---|---|
| `funes-mcp check` against the running app | launcher → endpoint file → listener verification (same user, Funes's bundle ID, holds the socket) → `server/discover`, `tools/list`, probe | **Pass:** key file 0600, key accepted for agent "Claude Code", 5 tools, "Funes Vault is on" |
| Claude Code connects through `funes-mcp` and lists categories | stdio launcher → real app | **Pass** |
| Codex connects through `funes-mcp`, requests memory, panel times out | stdio launcher → real app; nobody clicks | **Pass:** the Share panel was on screen (window list) for 45 s; `needs_approval` with the Spike 3 wording; Codex said "Waiting for your approval in Funes." |
| Request, approved in the panel | Claude Code → FUNES_MCP_TEST server (HTTP), fake responder allows | **Pass:** `delivered` in the call; Claude Code answered from it and relayed the withheld count |
| Request, denied | same, responder denies | **Pass:** `denied_by_user`; Claude Code said it won't ask again unless told |
| Timeout, then `get_memory_request` | same, no answer for 45 s; approved afterwards; the session resumed (`claude -p --resume`) as its timer would | **Pass:** `needs_approval` at 45.1 s; Claude Code relayed the sentence and backgrounded `sleep 60` (as in Spike 3); resumed, it called `get_memory_request` with the right `request_id`, got `delivered` and answered from it |
| Suggest into the Inbox | Claude Code as a suggest-only agent | **Pass:** `queued`, in the Inbox, the Save panel shown; Claude Code said it waits for the user's review |
| Panel approve and deny **by a person, in the real app** | The user, Debug build 1dad5fb, test vault `/tmp/funes-dev`, Claude Code, Claude Desktop and Cursor | **Pass** (2026-10-17): Share and Deny in the real panel worked with Claude Code, and the Save panel showed. Claude Desktop and Cursor sent `keywords` and waited the full 45 s. The panels' look and dark mode were checked; nothing to fix |

**Do agents send `keywords`?** Yes, unprompted, every time:
- **Claude Code:** 7–8 keywords per request, mixing kinds of context and candidate values, for example `["preferred package manager", "preferred test framework", "TypeScript preferences", "JavaScript tooling", "npm pnpm yarn bun", "Jest Vitest", "coding conventions"]`. It also sent a `purpose`, and once a `categories` narrowing after `list_memory_categories`.
- **Codex:** 9 keywords, `["TypeScript project", "package manager preference", "test framework preference", "npm", "pnpm", "yarn", "bun", "Vitest", "Jest"]`, plus `categories: ["software_development"]`, `retention: "none"` and `max_tokens: 500`.
- Both guess candidate values (`pnpm`, `Vitest`) besides kinds of context. That helps keyword retrieval, and the policy never depends on it. The description stays as it is. Claude Desktop and Cursor send `keywords` too (checked by hand, 2026-10-17).

**Found and fixed during the check:** a 45 s in-call wait ran to about 47 s, and a 55 s timeout could have run past 60 s. `Task.sleep` without a tolerance lets the system coalesce long timers by several percent. FunesCore's wait and BridgeKitCore's call timeout now pass an explicit 100 ms tolerance: 45 s → 45.1 s.


## Phase 4b live check: cloud agents through Remote Access
**Status:** connection and basic flows run on 2026-10-19, as reported by the user. The timeout measurement and the remaining rows are still open (task 4b.15). Results are also in [Testing](../../docs/TESTING.md#remote-access-live-check).

### Results so far (2026-10-19)
- **Build and setup:** the notarized 0.1.2 draft (build 3) installed from GitHub over the user's own app and vault, so not the development vault the set-up below describes. EK Bridge 0.11.4 (build 21) ran beside it.
- **Tunnel:** Tailscale 1.102.4, Funnel on port 443 shared by path. EK Bridge kept its `/` entry from before; Funes added its four paths with the `--set-path` commands. `tailscale funnel status` showed both. Funes's address was moved from 0.1.1's `:10000` to the address without a port with **Address ▸ Edit…**, and **Test** said Reachable.
- **claude.ai and ChatGPT:** both connected to Funes (custom connector with the MCP URL, pairing on the agent's Cloud tab), read memories, and suggested memories.
- **EK Bridge:** its claude.ai and ChatGPT connectors kept working throughout.
- **Reset Path…:** the move commands and reconnecting worked.
- **The failed first attempt:** on 0.1.1, with Funes on port 10000, the tunnel answered from the internet (checked through Tailscale's public relays), but claude.ai and ChatGPT both said they couldn't reach it. claude.ai only connects out on 443 ([anthropics/claude-ai-mcp#373](https://github.com/anthropics/claude-ai-mcp/issues/373)), and ChatGPT behaved the same. Hence path sharing on 443 ([plan](phase-4b-funnel-paths.md)).
- **Not recorded yet:**
  - deny;
  - no answer then `get_memory_request`, and how long each app waits for a tool call (the measurement below, with a Debug build and `FUNES_DEBUG_CALL_WAIT`);
  - `keywords`;
  - Revoke;
  - the Anthropic API with a remote token;
  - Turn Off Remote Access.

**Why it matters:** Spike 3 measured agents on the Mac only. A cloud agent that gives up on a tool call before Funes's 45 s in-call wait ends would see an error instead of `needs_approval`. Nothing in the policy changes with the result: the request is in Pending requests either way, and `get_memory_request` collects it.

### Set-up (a test build and a development vault; nothing touches the installed app or EK Bridge)
1. Build the Debug app from the `phase-4b/remote-access` branch (`xcodebuild … -configuration Debug`, as in AGENTS.md) and start it with a development vault and a long in-call wait:
   ```sh
   FUNES_DATA_DIR=/tmp/funes-remote-check FUNES_DEBUG_CALL_WAIT=290 \
     build/DerivedData/Build/Products/Debug/FunesVault.app/Contents/MacOS/FunesVault --dev-seed
   ```
   `FUNES_DEBUG_CALL_WAIT` (Debug builds only) makes `request_memory` wait up to 290 s for the panel (and the call answer at 300 s), so the cloud agent's own limit shows. Each time a client gives up, the app logs `request_memory call cancelled by the client after N s (remote: true)`:
   ```sh
   log stream --predicate 'subsystem == "com.funesvault.mac" AND category == "mcp"' --info
   ```
2. **Tailscale Funnel next to EK Bridge's, by path on 443.** EK Bridge's Remote Access uses Funnel's `/` on 443.
   - 0.1.1 put Funes on another public port. On 2026-10-19 that worked from the internet, but claude.ai and ChatGPT both failed: claude.ai only connects out on 443 ([anthropics/claude-ai-mcp#373](https://github.com/anthropics/claude-ai-mcp/issues/373)).
   - From 0.1.2, step 2 shows four `tailscale funnel --bg --https=443 --set-path …` commands, one per Funes path, beside EK Bridge's `/` ([plan](phase-4b-funnel-paths.md), with the Tailscale path test).
   - Run them. The address is `https://<mac>.<tailnet>.ts.net`, with no port.
   - Turn them off afterwards with the four off commands below them, never a bare `… off`.
3. In the test app: **Remote Access ▸ Set Up Remote Access…**, Tailscale Funnel, **Turn On Remote Access**, run step 2's commands, paste the address, then **Test** → Reachable. EK Bridge's Tunnel row still shows Running.
4. **Add Agent…** with the **claude.ai** tile (starting access *Read low-sensitivity memories, ask first*), and again with **ChatGPT**. For the header check, a third agent with the **Anthropic API** tile.

### Checks (per app)
| Step | claude.ai | ChatGPT |
|---|---|---|
| Pair: **Connect a Cloud App…**, add the connector with the MCP URL, codes match, **Allow** | | |
| `list_memory_categories` ("What categories does my Funes vault have?") | | |
| `request_memory`, **Share** in the panel → memories in the answer | | |
| `request_memory`, **Deny** → it says you declined | | |
| `request_memory`, **no answer**: the seconds until the app gives up (log line), and what it shows | | |
| then **Review** in Pending requests ▸ Share, ask again → `get_memory_request` delivers | | |
| `suggest_memory` ("Remember that I prefer dark mode") → queued, in the Inbox, Save panel | | |
| Sends `keywords` (Activity's request, or the panel's "Looking for") | | |
| **Revoke** → the next call fails and it asks to reconnect | | |

Anthropic API with the remote token (**Copy Remote Token…**, then the setup's `curl` with `FUNES_REMOTE_TOKEN`): the same requests; then **Reset Remote Token…** → the old token gets 401. Finally **Turn Off Remote Access** → the URL stops answering.

### What to record
- How long claude.ai and ChatGPT wait for a tool call (the log line), and their versions or dates.
- **If either waits less than 45 s:** with the shipped 45 s wait, that app would show an error before Funes answers `needs_approval`, and wouldn't learn the request id. The request still waits in Pending requests, and Activity shows it. Options, in order of preference: (a) keep 45 s and rely on the user asking again, since `get_memory_request` needs the id; (b) answer `needs_approval` sooner for remote calls, which ADR-0018 rules out as a channel difference unless it's only a transport timeout, not a policy (record it in an ADR); (c) a per-client wait keyed by `clientInfo.name`, as Spike 3 proposed for slow local clients.
