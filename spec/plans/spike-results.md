# Spike results

Results of the [Phase 0 spikes](phase-0-spikes.md). Each section gives the question, what was run, the numbers, and the decision it feeds.

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

### Decision (2026-10-16)
**Keyword search for v0.1; semantic search later as an opt-in** ([ADR-0015](../architecture/decisions/0015-keyword-search-first.md)). This is close to option 3, without Foundation Models expansion.
- **v0.1 search:** FTS5 BM25 with the `porter unicode61 remove_diacritics 2` tokenizer, for both vault search and agent retrieval. There are no embeddings, so `semantic` is 0.
- **Regression baseline:** FTS5 porter recall@5 ≥ 0.56 on these fixtures (Phase 1 task 1.4).
- **Later:** an Embeddings row in Settings ▸ AI Models, off by default. It offers a local server, a cloud model, or a bundled open model; the bundled option (1 above) needs a Spike 2b first. Any option must beat the keyword baseline. Foundation Models query expansion for agent retrieval is on the roadmap as a separate later option.

---

## Spike 3: Agent timeouts and the in-call approval
**Run:** 2026-10-16. **Code:** [`spikes/agent-timeouts/`](../../spikes/agent-timeouts/README.md), a throwaway stdio MCP server (Python standard library) plus a log reader.
**Status:** **provisional pass.** Claude Code passes, measured. Claude Desktop and Cursor still need a manual run (checklist in the spike README) before Q10 is closed.

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
| Claude Desktop | Manual. Issue threads report a fixed ~60 s | — | — | — | — |
| Cursor | Manual. Staff: ~60 min in the IDE, a hardcoded 60 s in the CLI/ACP | — | — | — | — |
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
- Send `notifications/progress` with "Waiting for your approval in Funes…" during the in-call wait, when the client sent a `progressToken`. Don't rely on it to extend timeouts.
- Keep the in-call wait one constant. Log `clientInfo.name` with each request so a per-kind override can be added if a manual row comes in below ~50 s.
- Document per-agent behaviour in `docs/MCP.md` (Phase 4), from the completed table.

Fallback, unchanged from the plan: if Claude Desktop or Cursor turns out to cut off before ~50 s, make the wait per agent kind (for example 20 s for that client). If several do, return `needs_approval` immediately. Both measured agents handled the immediate-return path well.

**Before closing Q10:** fill the Claude Desktop and Cursor rows, plus Claude Code interactive (`claude_tui.sh approval`), using the spike README checklist. Then mark Q10 decided in [open-questions.md](open-questions.md).
