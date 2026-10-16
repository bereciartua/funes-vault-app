# Open questions and decisions

Each has a recommendation (★). Decide before the phase listed, and record the answer as an ADR when it's architectural.

| # | Question | Options | ★ Recommendation | Decide before |
|---|---|---|---|---|
| Q1 | **Product name** | Funes · Funes Memory · Funes Vault · Funes Mind · … | **Decided: Funes Vault.** "Funes" already means memory (Borges); "Vault" adds the missing half, control. It's different from the existing iPhone app "FUNES." (a 3D heritage archive), reuses the Funes Vault logo system, and the App Store subtitle carries "Private memory for AI agents". "Funes" stays as the short form in UI copy | Decided 2026-10-16 |
| Q2 | **Price** | Free & open source · Paid Mac app · Free Mac + paid iPhone · Free + paid "Pro" | **Free & open source for the preview**, like EK Bridge. Revisit at 1.0 if usage is real; a paid iPhone app is the cleanest later option | Phase 4 |
| Q3 | **License** | Apache-2.0 · MIT · source-available | **Decided: Apache-2.0**, matching EK Bridge and Funes Vault. `LICENSE` is in the repo from the first commit | Decided 2026-10-16 |
| Q4 | **Repository** | New repo · inside `funes-vault` | **Decided: new repo `bereciartua/funes-vault-app`.** `funes-vault` (the web version) stays as a historical artifact | Decided 2026-10-16 |
| Q5 | **Minimum macOS** | 14 (like EK Bridge) · 15 · 26 | **Decided: 15**: broad reach. Foundation Models features gated to 26+ | Decided 2026-10-16 |
| Q6 | **Minimum iOS** | 17 · 18 · 26 | **18**: needed for Controls; SpeechAnalyzer gated to 26+ | Phase 5 |
| Q7 | **Encryption at rest** | FileVault only · SQLCipher with a Keychain key | **FileVault only for v0.1**. SQLCipher adds a dependency and key handling for limited gain against the same-user threat model | Phase 1 |
| Q8 | **BridgeKit timing** | Copy now, extract later · Extract first · Tiered | **Decided: tiered.** Extract the protocol and security core now (EK Bridge adopts it first); copy UI pieces and extract after v0.1; Remote Access later ([ADR-0013](../architecture/decisions/0013-shared-bridgekit-core.md)) | Decided 2026-10-16 |
| Q9 | **Project generation** | Plain Xcode project · XcodeGen/Tuist | **Decided: plain Xcode project** (`FunesVault.xcodeproj`, with folder-synchronized groups so adding files doesn't touch the project file); switch if merge conflicts hurt | Decided 2026-10-16 |
| Q10 | **In-call approval wait** | 45 s for all · per agent kind · return immediately | **Decided by Spike 3**; default 45 s | Phase 2 |
| Q11 | **Allow window (FR-D-12)** | Ship in v0.1 · later · never | **Later**: it's a convenience that weakens the "always see what's shared" story. Ship only if daily use shows panel fatigue | Phase 3 |
| Q12 | **Agents editing memories** | Suggest-only corrections · update tool with Write | **Suggest-only corrections in v0.1** ([FR-S-06](../product/03-requirements.md)) | Phase 2 |
| Q13 | **Custom categories in v0.1** | Yes · later | **Yes (Should)**: needed for real-world allow/deny rules | Phase 3 |
| Q14 | **AI models** | On-device only · user-selectable | **Decided: user-selectable per task, Apple on-device by default**, with a cloud sensitivity limit and disclosure ([ADR-0014](../architecture/decisions/0014-user-selectable-models.md)) | Decided 2026-10-16 |
| Q21 | **Default cloud sensitivity limit** | Low · Internal · Sensitive | **Internal**: covers preferences, projects and work context; keeps health, money and family off cloud models unless the user raises it | Phase 3 |
| Q22 | **Providers in v0.1** | All listed · subset | **Apple on-device, OpenAI-compatible (covers OpenAI, Ollama, LM Studio, Gemini, OpenRouter, custom), Anthropic.** Apple Private Cloud Compute if the entitlement is granted in time | Phase 1 |
| Q15 | **Remote Access for cloud agents (claude.ai, ChatGPT)** | v0.3 · never | **v0.3**, reusing EK Bridge's OAuth once its live cloud matrix has been run | After v0.2 |
| Q16 | **Push to the iPhone for approvals** | CloudKit "doorbell" · none | **None until asked for**. If added, CloudKit with no memory data, only "you have a request" | After v0.2 |
| Q17 | **Web version (funes-vault)** | Keep as is · archive later | **Decided: keep as a historical artifact.** At production readiness (1.0), add a "no longer maintained" note to its README with a link to the new repo | Decided 2026-10-16 |
| Q18 | **Command-line tool** (`funes` for scripts) | v0.1 · later | **Later**. EK Bridge's signed CLI transport can be reused | After v0.2 |
| Q19 | **Localization** | English only · + Spanish | **English only in v0.1**, using String Catalogs from day one; Spanish is an easy early addition | Phase 4 |
| Q20 | **Activity retention defaults** | 400 days important / 30 days other · user-configurable | **These defaults, configurable in Advanced** | Phase 3 |
| Q23 | **Domain** | Buy a domain · keep `io.github.bereciartua.*` | **Decided: funesvault.com** (bought 2026-10-16). Bundle IDs `com.funesvault.*`, MCP Registry `com.funesvault/funes`, website, privacy and support URLs on it. Optionally also register `funesvault.app` and redirect it. **Done:** "Funes Vault" reserved in App Store Connect; App IDs and App Group registered. **Still to do:** search trademarks for "FUNES VAULT" and "FUNES" in classes 9 and 42. (Name research: an iPhone app "FUNES." by AAANY Limited exists; `funes.io`, `.co`, `.me`, `.app`, `.dev`, `.ai` and `.so` are taken) | Decided 2026-10-16 |

## Background: name and domain research (Q1, Q23)
- **Taken:** `funes.io` (since 2016), `funes.co` (2019), `funes.me` (2023), `funes.app`, `funes.dev`, `funes.ai`, `funes.so`, `funesmemory.app` (registered Jan 2026, parked), `usefunes.com` (Feb 2026, parked).
- **Not registered at the time:** `funesmemory.com`, `funesmemory.io`, `getfunes.com`, `getfunes.app`, `getfunes.io`, `usefunes.app`, `funesapp.com`, `funesapp.io`, `funes.sh`, `funes.to`, `funes.cc`, `funes.page`, `funes.xyz`, `funeshq.com`, `withfunes.com`, `funesvault.app` (`funesvault.com` has since been bought).
- **Existing app:** an iPhone app called **"FUNES."** (AAANY Limited, funes.world; a 3D cultural-heritage archive, released Feb 2026) exists, which is why the store name is qualified as "Funes Vault".
