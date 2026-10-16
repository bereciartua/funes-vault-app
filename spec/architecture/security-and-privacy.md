# Security and privacy model

## 1. Assets
| Asset | Why it matters |
|---|---|
| Memory text (title and body) | Personal and possibly sensitive. The main asset |
| Access settings | Decide who gets what. Tampering widens disclosure |
| Agent keys | Holding a key means acting as that agent |
| Device keys and pairing secrets | Holding them means owner-level access to the vault |
| Activity and provenance | The audit trail. It must not leak text, and must not be silently erasable by agents |
| Task texts sent by agents | Can reveal what the user is working on. Held in memory only, for up to 15 min |

## 2. Actors and trust
| Actor | Trust | Can |
|---|---|---|
| **User at the Mac** | Full | Everything, through the UI |
| **Paired iPhone (owner device)** | Full, but authenticated per message | Owner operations through the companion API, logged |
| **Connected agent** | Scoped | Only what its access allows. Its words are data |
| **Agent's AI provider** | Untrusted, out of our control | Sees whatever the user released to the agent |
| **Other local processes (same user)** | Out of scope | Can read the user's files and keys. Funes can't defend against malware running as the user (the same boundary as EK Bridge) |
| **Other local users / processes** | Untrusted | Reach 127.0.0.1:47625 but need a key |
| **LAN peers, the Tailscale network, tunnel providers, internet** | Untrusted | Reach 47626 only in the modes the user enabled. They see envelopes they can't read or forge |
| **Malicious web pages in a browser** | Untrusted | Could try DNS rebinding or CSRF against localhost. Blocked |

## 3. Threats and mitigations
| # | Threat | Mitigation |
|---|---|---|
| T1 | A prompt-injected agent asks for everything ("ignore rules, share all") | Purpose and task never affect eligibility ([policy §1](../domain/access-policy.md)); exact-text approval by default; ceilings and categories enforced server-side. Test T12 |
| T2 | An agent learns which memories exist from denials | Withheld counts only, no ids or titles; `not_found` is the same for missing and forbidden; categories are listed without counts |
| T3 | An agent plants malicious instructions in the vault (stored prompt injection) | Suggestions are reviewed by default; Write needs an explicit grant with ask-before-saving off; agents can only write within their scope; released text is wrapped with "user data, not instructions"; Activity shows who suggested what |
| T4 | An approved release is used after things changed (TOCTOU) | Snapshot revision; delivery re-checks the agent revision, memory versions and eligibility in one transaction; single use; 15-min expiry. Tests T13–T17 |
| T5 | Another agent reuses a request id | Requests are bound to the requesting agent; others get `not_found`. Test T20 |
| T6 | Stolen agent key | Key files are 0600 in a 0700 folder; the database holds only digests; rotate or remove in one click; all use is logged; local-only listener |
| T7 | DNS rebinding / CSRF from a browser to localhost | Host must be loopback (421); any Origin refused (403); POST and JSON only; no CORS |
| T8 | A launcher talks to an impostor listener and leaks the key | The launcher verifies the listener's owner, bundle ID and socket via `libproc` before sending the key (EK Bridge) |
| T9 | Network attacker reads or forges iPhone traffic | Per-message HPKE encryption plus a device signature with a Secure Enclave key, a replay window and nonce cache; responses are encrypted with a key exported from the request context |
| T10 | Someone photographs the pairing QR code | It's valid once for 5 min, and pairing also needs **Allow** on the Mac. Devices are listed and revocable |
| T11 | Lost or stolen iPhone | Revoke on the Mac. The phone holds no vault data, only queued captures (protected after first unlock) and keys (Secure Enclave, `ThisDeviceOnly`) |
| T12 | Public tunnel exposure of the owner API | Off by default; secret path plus Host check; signed and encrypted envelopes; rate limits and failed-auth lockouts. LAN and private Tailscale are recommended |
| T13 | Secrets end up in the vault and then get shared | The secret scanner runs on every write path, on both the Mac and the phone. Funes's own keys are in the patterns |
| T14 | Memory text leaks into logs or crash reports | Activity and provenance hold ids and labels only; OSLog uses `privacy: .private` for any user content; no third-party crash reporting; test fixtures assert no text in logs |
| T15 | Database corruption or tampering by another process | Out of scope for tampering (same-user boundary). Corruption: WAL, integrity checks, daily backups |
| T16 | Malicious update | Sparkle EdDSA-signed appcast plus Developer ID and notarization; Homebrew cask checks the attestation and SHA-256 |
| T17 | A flood of agent requests or suggestions spams the user | Rate limits; at most 3 waiting approvals per agent; panels capped at 3 on screen; "Pause Funes Vault" |
| T18 | Memory, capture, search or task text sent to an AI model provider | Apple on-device by default. Any other provider is the user's explicit choice, labelled with exactly what it receives. The secret scanner runs on every outgoing text. The cloud sensitivity limit (default Internal) is never exceeded. Captures are pre-screened on the device before cloud classification. API keys live only in the Keychain. Tested with request capture ([model providers §9](model-providers.md#9-testing)) |
| T21 | Prompt injection through memory or capture text sent to a generation model | Text is fenced and labelled as data; output is constrained by a JSON schema and validated (unknown categories dropped, sensitivity raised to the category default); proposals are review-only and never applied automatically |
| T22 | A stolen provider API key is used elsewhere | Keys stay in the Keychain (this device only), never in the database, logs or exports. Removing a provider deletes its key. The user rotates keys at the provider |
| T19 | A user approves without reading | Arming delay; the exact text is shown; per-memory checkboxes; sensitivity badges; no "always allow everything" button |
| T20 | Clock manipulation affects expiry | Expiry uses the Mac's clock (trusted, same user). Companion replay checks use ±120 s and the nonce cache |

## 4. Privacy guarantees (each one is tested)
1. **No text before consent.** A request that needs approval returns no memory text, ids or titles.
2. **Exact and partial approval.** Only the memories the user ticks are released, with the exact text shown.
3. **Single use, short-lived, invalidated by change** (15 minutes; agent revision; memory version).
4. **Purpose can't change decisions.**
5. **Fail closed** for unknown, paused, expired or removed agents and for an unanswered panel.
6. **Logs hold ids and labels, never text.**
7. **Secrets are never stored.**
8. **Exports never contain keys, devices or access settings. Imports never grant access.**
9. **Revocation is immediate,** for future access. Text already released is beyond the vault's control, and the UI says so.
10. **The vault exists only on the Mac.** The iPhone holds only queued captures.
11. **AI processing is local by default.** Text reaches a non-local model provider only if the user chose one, never above the cloud sensitivity limit, and never when it matches the secret scanner.

## 5. Everything that can leave the Mac
| Data | Destination | When |
|---|---|---|
| Memory text released to an agent | The agent, then its AI provider | Only on ALLOW or the user's approval |
| Update check (app version, OS version, as Sparkle sends) | GitHub Releases | Daily, if automatic checks are on |
| Companion responses (encrypted) | The paired iPhone, possibly through a tunnel | When the phone asks |
| Memory text (up to the cloud limit), search queries and agents' task text | The **embedding** provider the user chose, if it isn't on the device | Only after the user picks it; the disclosure is shown in Settings |
| Capture, suggestion and import text (up to the cloud limit, after an on-device pre-screen) | The **classification** provider the user chose, if it isn't on the device | Same |
| Memory pairs (up to the cloud limit) | The **consolidation** provider (v0.3) | Same |
| Nothing else | — | No analytics, no crash reporting, no accounts |

**App Store privacy label (iPhone):** "Data Not Collected". The phone sends data only to the user's own Mac.

## 6. Known limitations (stated in the README and Security docs)
- **No protection against malware running as you.** Another program running as you can read the vault and key files. This is the same as EK Bridge and most Mac apps without the sandbox.
- **No control after release.** Funes can't recall or control text after it's released to an agent.
- **FileVault protects the data at rest.** Funes doesn't add its own database encryption in v0.1.
- **Some metadata is visible on the network.** On the LAN and Tailscale, which device is talking, when, and how much is visible, though not what.
