# ADR-0022: The user sets the cloud limit, up to everything; one limit for every task; a daily request cap

**Status:** Accepted · 2026-10-23 · **Amends** [ADR-0014](0014-user-selectable-models.md) (guardrails) and FR-AI-07

**Context.**
- **Today's cloud limit** stops at Sensitive ("Public · Low · Internal · Sensitive · Never send captures") and only captures go to a provider.
- **With [ADR-0020](0020-atomic-extraction-for-every-source.md) and [ADR-0021](0021-daily-tidy-up.md)** far more goes out: agent suggestions, imports, existing memories, and later embeddings ([ADR-0023](0023-provider-embeddings-second-index.md)).
- **Users differ.** Some are happy to send anything to a provider they pay for; others want nothing sensitive to leave the Mac. Funes's promise is control, not a particular level.
- **The guard today checks one sensitivity per request** and trusts the declared level, so an agent with a Low ceiling, which can only declare Low, always passes; imports have no level and are always blocked.
- **Cost:** a large import or the first tidy-up of a big vault can make hundreds of requests, and one agent can store 250 writes a day.

**Decision.**
1. **The limit goes up to everything:** "Send memories to cloud models up to: Public · Low · **Internal (recommended)** · Sensitive · Restricted · Everything, including Secret · Nothing". Choosing above Internal asks once to confirm, naming the provider. Local providers aren't limited. **The secret scanner is never optional.**
2. **One limit for every task** (New memories, the tidy-up, embeddings), so there's one sentence to understand.
3. **The guard covers every item in a call** (`ModelRouter.send` takes typed items) and uses the highest sensitivity among them. Agent and import text is **pre-screened on the device** (rules, plus the on-device model where available), and the guard uses the higher of the pre-screen and the declared level. Unknown sensitivity is still treated as above the limit.
4. **A daily cap on cloud generation requests,** 300 by default, adjustable, counted per local day and kept across restarts. Shared by New memories and the tidy-up; embeddings don't count.
   - **Agents** may use at most 40% of the cap, so the user's own captures aren't starved.
   - **At the cap,** the user's captures fall back to on-device; agent input, imports and the tidy-up wait for the next day rather than being processed by a weaker model. A notice says so once.
   - **Import previews** show the estimated requests next to what's left today.

**Consequences.**
- **PRIVACY.md and the disclosure lines** say what goes where at each level when the code lands.
- **Embeddings send the most** (every memory within the limit, every search, every agent task), and the one limit covers them too, so their disclosure line spells out the volume.
- **No consent migration:** there are no external users yet.

**Alternatives considered.**
- **A limit per task:** more control, harder to explain; one limit now, revisit if users ask.
- **Keep the ceiling at Sensitive:** takes the choice away from users who want it.
- **No cap, only usage counters:** a big import or a misbehaving agent could run up the user's bill.
- **Fall back to on-device at the cap for everything:** silently lowers quality for background work that can wait.
