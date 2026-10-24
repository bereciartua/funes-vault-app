# ADR-0024: Claude and ChatGPT subscriptions as model providers, through the user's own Claude Code and Codex

**Status:** Accepted · 2026-10-23 · **Amends** [ADR-0014](0014-user-selectable-models.md) (the provider list)

**Context.**
- **Many users already pay for Claude or ChatGPT** and use them through Claude Code or Codex. Asking them for an API key as well means a second bill and a second setup. The author is one of them.
- **Spike E ran through exactly these CLIs** ([results](../../plans/spike-results.md#spike-e-extraction-linking-and-tidy-up-quality)): Claude Haiku 5.5 and Opus 5.5 through `claude -p --json-schema`, GPT-6-Luna and GPT-5.6-Terra through `codex exec --output-schema`, on the user's subscriptions. The auto-apply levels it measured are for these engines.
- **What the vendors allow** (read 2026-10-23):
  - Anthropic's [legal and compliance page](https://code.claude.com/docs/en/legal-and-compliance.md) doesn't let third-party developers offer Claude.ai login, or route requests through Free, Pro or Max credentials on their users' behalf. It does allow running Claude Code in a product when the developer accepts the Commercial Terms: the binary must be unmodified and keep every sign-in method, the developer may not pay for or resell usage, and each end user signs in with their own credentials. It also says nothing prevents an end user from signing in to the unmodified binary with their own subscription. Pro and Max limits assume "ordinary, individual usage".
  - OpenAI's [non-interactive mode docs](https://learn.chatgpt.com/docs/non-interactive-mode.md) describe ChatGPT-managed auth for `codex exec` for users who need ChatGPT or Codex rate limits instead of an API key, and recommend an API key for automation in CI.
- **Isolation differs.** Claude Code has documented flags to run with no built-in tools, no MCP servers, no hooks and no CLAUDE.md. Codex has no "no tools" mode: its read-only sandbox still runs commands that read files, and version 0.164 turns on browser and computer use by default. Tools can be turned off one feature at a time (`--disable shell_tool`, …), and new versions add features turned on.
- **Data terms differ from the API.** Subscription use falls under the user's consumer account: their training setting decides whether the text can train models. API use is never used for training.

**Decision.**
1. **A new provider kind, "Subscription",** with two providers: **Claude (Claude Code)** and **ChatGPT (Codex)**. Generation only (neither offers embeddings). Locality: cloud, so every guardrail applies: the secret scanner, the cloud limit, the multi-item guard, the daily cap ([ADR-0022](0022-cloud-limit-and-daily-cap.md)).
2. **Funes never touches the user's credentials.** It runs the CLI the user installed, unmodified, found on the Mac. It never bundles, installs or depends on it (no Homebrew dependency). Sign-in happens in the CLI's own flow: Funes shows the command to run in Terminal. Funes doesn't read, store or pass on tokens, and doesn't pay for or resell usage.
3. **Every call is isolated, and fails closed if it isn't:**
   - It runs in a new empty temporary directory outside any repository, with an environment stripped of API keys (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CODEX_API_KEY`, `OPENAI_API_KEY`), so the subscription is what's used. Nothing is persisted, and telemetry and error reporting are off where the CLI allows it.
   - **Claude Code:** `claude -p` with `--safe-mode --tools "" --disallowedTools "mcp__*" --strict-mcp-config`, hooks off through `--settings`, `--no-session-persistence`, the task's `--system-prompt` and `--json-schema`, and `--output-format stream-json`. It never uses `--bare`, which skips subscription sign-in. The start event must list no MCP servers, plugins or hooks, and no tool but the structured-output one; otherwise the run is stopped and its output discarded.
   - **Codex:** `codex exec` with `--ignore-user-config --ignore-rules --ephemeral --skip-git-repo-check --sandbox read-only`, `-C` to the empty directory, `--output-schema`, `--json`, and `--disable` for every tool feature (shell, exec, browser, computer use, apps, plugins, hooks, image tools…). Funes keeps a list of the features it knows are safe to leave on. **Any enabled feature not on that list** (a newer Codex) makes the provider "Unavailable: this Codex version isn't supported yet", until Funes is updated. **Any tool or command event** in the JSON stream stops the run and discards its output.
   - **Amended 2026-10-24, after the first live run** (Claude Code 2.1.310, Codex 0.164.0):
     - Claude Code's start event lists its own built-in plugins, which `--safe-mode` doesn't turn off, and its built-in agent types. Built-in plugins on Funes's known list are accepted (an installed plugin or an unknown built-in one still stops the run), and agent types are accepted, since neither can act with `StructuredOutput` as the only tool.
     - Codex keeps `unified_exec` (running commands that can read files) on whatever Funes asks. Codex is therefore **an opt-in, off by default**, behind a plain warning that it can read files on the Mac. With the opt-in on, the feature check accepts `unified_exec` and nothing else, and any command event still stops the run and discards its output. Decided by the author.
   - **Minimum versions** with the needed flags; an older CLI is "Unavailable: update Claude Code" (or Codex).
4. **Plain disclosure:** "New memories sends captures, agent suggestions and imports, plus related memories (up to Internal), to Claude through your Claude Code sign-in. It counts toward your plan's limits, and your Claude account's training setting applies." The same for ChatGPT through Codex. The settings link opens the vendor's privacy settings.
5. **Usage:** each call counts toward the daily cap like any cloud request; token counts come from the CLI's output when it reports them. Timeout: 90 s per call (Codex averaged 7–21 s in Spike E, plus the CLI's start-up), which is fine for background work.
6. **Auto-apply levels stay per engine (model id):** the levels Spike E measured for Haiku, Opus, Luna and Terra apply whichever way the model is reached, subscription or API.
7. **Owner obligations:** the Funes project accepts Anthropic's Commercial Terms for running Claude Code in the product, and drops a provider if a vendor's terms change or the vendor asks. Confirming with Anthropic's sales contact is recommended before a public release that includes it.

**Consequences.**
- **No API key needed** for users with a Claude or ChatGPT plan, and the author's week of daily use in [Phase 6a](../../plans/phase-6a-new-memories.md) can run on their subscription.
- **More fragile than an HTTP API:** CLI flags and output formats change between versions. Contract tests over recorded CLI output, the version check, the feature list and a live smoke test before each release that touches the adapters.
- **Codex costs more per call:** its own tool descriptions add 6–9k tokens to every call (Spike E), counted against the user's plan.
- **The privacy story has two cases:** API keys (never used for training) and subscriptions (the user's own account settings). PRIVACY.md says both when the code lands.
- **The Codex feature list needs upkeep** with each Codex release; until it's updated, Codex is unavailable rather than unsafe. So does the list of Claude Code's built-in plugins.
- **Codex carries a residual risk the user accepts:** with the opt-in on, a prompt injection could make Codex read a file before Funes sees the command event and stops the run. The read happens in a read-only sandbox with no internet, the output is discarded, and pieces must quote the input, so file contents can't become memories; but the model provider sees what was read.

**Alternatives considered.**
- **API keys only:** simplest and the clearest terms, but a second bill and setup for subscription users.
- **Use the subscription's OAuth tokens directly, or offer "Sign in with Claude":** not permitted by Anthropic, and Funes would handle credentials.
- **The Claude Agent SDK with a Claude.ai login:** not permitted unless Anthropic approves.
- **Claude Code only:** avoids Codex's tool problem, but leaves out ChatGPT users. Chosen instead: Codex with a fail-closed feature check.
