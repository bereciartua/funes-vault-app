# Storage

## 1. Files on disk (Mac)
Everything lives under `~/Library/Application Support/FunesVault/`, in a 0700 folder with 0600 files owned by the user. Loading **fails closed** on a wrong owner or mode, a symlink (`O_NOFOLLOW`), or an oversize file. This is EK Bridge's file-safety pattern.

| Path | Contents | Notes |
|---|---|---|
| `vault.sqlite` (+ `-wal`, `-shm`) | Memories, categories, suggestions, agents, access, disclosures, devices, receipts, provenance, embeddings, FTS | GRDB `DatabasePool`, WAL mode |
| `agent-keys/<agentId>.key` | The agent's MCP key, bare with no newline | Written once, never read back except by **Copy key**. Deleted on removal |
| `agent-keys/<agentId>.remote.key` | The agent's Remote Access token (`fns_mcpr_v1_`), bare | Only with Allow cloud access. Read back only by **Copy Remote Token…**. Replaced by **Reset Remote Token…**; deleted when cloud access is turned off or the agent is removed ([ADR-0018](decisions/0018-remote-access-in-v0.1.md)) |
| `remote-connections.json` | Remote Access OAuth state: connected cloud apps (agent id, app name, OAuth client id, MCP URL, SHA-256 digests of the access, refresh and recently rotated refresh tokens, expiry and use times) and registered OAuth clients (`dcr_`, and `cfg_` with the digest of its `fns_ocs_v1_` secret) | BridgeKitRemote's `OAuthStore`: written atomically with fsync, fails closed (a wrong owner, mode, size or content makes OAuth unavailable and the file is never overwritten). No token in the clear. Never exported |
| `activity/activity.jsonl` | Activity log, append-only | BridgeUI `ActivityStore` (copied from EK Bridge); `fsync` per row |
| `mcp-endpoint.json` | `{"version":1,"url","port","pid","startedAt"}` | Only while listening |
| `Backups/vault-YYYYMMDD-HHMM.sqlite` | Online backups (GRDB `backup(to:)`) | Daily, keep 7; also before each migration |
| `companion/` (v0.2) | Replay-nonce cache snapshot (optional) | Keys live in the Keychain, not here |

- **Keychain:** Mac signing and HPKE keys, and **AI provider API keys** (service `com.funesvault.provider`), all with `ThisDeviceOnly` accessibility.
- **AI provider settings** (provider definitions without keys, the per-task model choice, the cloud sensitivity limit, usage counters) live in user defaults. They're never exported.
- **User defaults:** UI preferences, the hotkey, ports, iPhone access modes, update settings, setup checklist state.
- **Nothing** lives in `/tmp`. Unlike EK Bridge, there's no file transport.

**Encryption at rest:** relies on FileVault in v0.1 ([Q7](../plans/open-questions.md), decided). SQLCipher may be revisited later.

## 2. Schema (v1)
SQLite with `PRAGMA foreign_keys = ON`, `journal_mode = WAL` and `synchronous = NORMAL`. Times are stored as UTC text in GRDB's `Date` format (`YYYY-MM-DD HH:MM:SS.SSS`, which sorts and compares as text). Ids are lowercase UUID text.

```sql
CREATE TABLE category (
  key                 TEXT PRIMARY KEY,           -- slug, immutable
  name                TEXT NOT NULL,
  description         TEXT NOT NULL DEFAULT '',
  builtin             INTEGER NOT NULL DEFAULT 0,
  default_sensitivity INTEGER NOT NULL DEFAULT 1, -- 0 public … 5 secret
  sort_order          INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE memory (
  seq               INTEGER PRIMARY KEY,        -- stable rowid for the FTS external content (see below)
  id                TEXT NOT NULL UNIQUE,
  title             TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 180),
  body              TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 10000),
  kind              TEXT NOT NULL,
  sensitivity       INTEGER NOT NULL CHECK (sensitivity BETWEEN 0 AND 5),
  status            TEXT NOT NULL CHECK (status IN ('active','archived','deleted')),
  expires_at        TEXT,
  confidence        REAL,
  source            TEXT NOT NULL,
  source_agent_id   TEXT REFERENCES agent(id),
  source_device_id  TEXT REFERENCES device(id),
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL,
  last_confirmed_at TEXT,
  deleted_at        TEXT,
  version           INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX memory_status_updated ON memory(status, updated_at DESC);
CREATE INDEX memory_expires ON memory(expires_at) WHERE expires_at IS NOT NULL;

CREATE TABLE memory_category (
  memory_id    TEXT NOT NULL REFERENCES memory(id) ON DELETE CASCADE,
  category_key TEXT NOT NULL REFERENCES category(key) ON UPDATE CASCADE,
  PRIMARY KEY (memory_id, category_key)
);
CREATE INDEX memory_category_by_category ON memory_category(category_key);

-- Full-text index (external content); kept in sync by triggers
CREATE VIRTUAL TABLE memory_fts USING fts5(
  title, body, content='memory', content_rowid='seq',
  tokenize='porter unicode61 remove_diacritics 2'
);
-- triggers memory_ai / memory_ad / memory_au insert/delete/update memory_fts rows
-- memory.seq: a table whose primary key isn't an INTEGER PRIMARY KEY can get new rowids on VACUUM,
-- which would detach the external-content FTS rows. Ids stay the UUID text in memory.id.

CREATE TABLE embedding (           -- ADR-0016: about 15 MB of vectors at 10,000 memories
  memory_id    TEXT NOT NULL REFERENCES memory(id) ON DELETE CASCADE,
  model_id     TEXT NOT NULL,      -- "bge-small-en-v1.5/coreml-int8" (384 dims) on every memory; v0.3 a second index, "<provider>/<model>", e.g. "openai/text-embedding-3-small" (1,536)
  dims         INTEGER NOT NULL,
  vector       BLOB NOT NULL,      -- Float32 little-endian, L2-normalized
  content_hash TEXT NOT NULL,      -- SHA-256 of the embedded text
  PRIMARY KEY (memory_id, model_id)  -- bge-small and, v0.3, one provider model (ADR-0023)
);
-- v0.3: meta('provider_embeddings') = {"modelID", "limit"} once the provider set is complete for that model and
-- cloud limit (search uses it only then). The choice and Calibrate's thresholds live in user defaults (AI Models).

CREATE TABLE provenance (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  memory_id      TEXT NOT NULL REFERENCES memory(id) ON DELETE CASCADE,
  at             TEXT NOT NULL,
  event          TEXT NOT NULL,     -- created, edited, archived, restored, deleted, shared, …
  actor          TEXT NOT NULL,     -- user | agent:<id> | device:<id> | import:<id>
  fields_changed TEXT               -- JSON array of field names, no values
);
CREATE INDEX provenance_memory ON provenance(memory_id, at DESC);

CREATE TABLE agent (
  id                 TEXT PRIMARY KEY,
  name               TEXT NOT NULL,
  agent_kind         TEXT NOT NULL,
  key_digest         BLOB,            -- SHA-256 of key; NULL after removal
  key_issued_at      TEXT,
  paused             INTEGER NOT NULL DEFAULT 0,
  revision           INTEGER NOT NULL DEFAULT 1,
  declared_retention TEXT NOT NULL DEFAULT 'unknown',
  asks_for_access    INTEGER NOT NULL DEFAULT 0,
  first_request_at   TEXT,
  last_request_at    TEXT,
  created_at         TEXT NOT NULL,
  removed_at         TEXT,
  -- v2_remote_access (ADR-0018):
  cloud_access         INTEGER NOT NULL DEFAULT 0,
  remote_key_digest    BLOB,          -- SHA-256 of the remote token; NULL without cloud access
  remote_key_issued_at TEXT
);
CREATE UNIQUE INDEX agent_active_name ON agent(name) WHERE removed_at IS NULL;
CREATE UNIQUE INDEX agent_key_digest ON agent(key_digest) WHERE key_digest IS NOT NULL;
CREATE UNIQUE INDEX agent_remote_key_digest ON agent(remote_key_digest) WHERE remote_key_digest IS NOT NULL;

CREATE TABLE access (
  agent_id           TEXT PRIMARY KEY REFERENCES agent(id) ON DELETE CASCADE,
  op_read            INTEGER NOT NULL DEFAULT 0,
  op_suggest         INTEGER NOT NULL DEFAULT 0,
  op_write           INTEGER NOT NULL DEFAULT 0,
  max_sensitivity    INTEGER NOT NULL DEFAULT 1,
  ask_before_sharing INTEGER NOT NULL DEFAULT 1,
  ask_before_saving  INTEGER NOT NULL DEFAULT 1,
  expires_at         TEXT
);

CREATE TABLE access_category (
  agent_id     TEXT NOT NULL REFERENCES agent(id) ON DELETE CASCADE,
  category_key TEXT NOT NULL REFERENCES category(key) ON UPDATE CASCADE ON DELETE CASCADE,
  mode         TEXT NOT NULL CHECK (mode IN ('allow','deny')),
  PRIMARY KEY (agent_id, category_key, mode)   -- a key may be on both lists; deny wins (T8)
);

CREATE TABLE disclosure (
  id                       TEXT PRIMARY KEY,
  agent_id                 TEXT NOT NULL REFERENCES agent(id),
  agent_revision           INTEGER NOT NULL,
  task_hash                TEXT NOT NULL,
  task_length              INTEGER NOT NULL,
  purpose                  TEXT,
  retention                TEXT NOT NULL,
  processors               TEXT NOT NULL DEFAULT '[]',   -- JSON
  max_tokens               INTEGER NOT NULL,
  requested_categories     TEXT NOT NULL DEFAULT '[]',   -- JSON
  status                   TEXT NOT NULL,
  reason                   TEXT,
  candidate_snapshot       TEXT,                         -- JSON [{id,version}]
  snapshot_revision        TEXT,
  approved_memory_ids      TEXT,                         -- JSON
  approval_expires_at      TEXT,
  withheld                 TEXT NOT NULL DEFAULT '{}',   -- JSON {reason:count}
  created_at               TEXT NOT NULL,
  decided_at               TEXT,
  delivered_at             TEXT
);
CREATE INDEX disclosure_agent_status ON disclosure(agent_id, status);
CREATE INDEX disclosure_pending ON disclosure(status, created_at) WHERE status IN ('needs_approval','approved');

CREATE TABLE disclosure_item (
  disclosure_id    TEXT NOT NULL REFERENCES disclosure(id) ON DELETE CASCADE,
  memory_id        TEXT NOT NULL,      -- no FK: memory may later be purged
  memory_version   INTEGER NOT NULL,
  category_key     TEXT NOT NULL,
  sensitivity      INTEGER NOT NULL,
  estimated_tokens INTEGER NOT NULL,
  clipped          INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (disclosure_id, memory_id)
);
CREATE INDEX disclosure_item_memory ON disclosure_item(memory_id);

CREATE TABLE suggestion (
  id               TEXT PRIMARY KEY,
  origin           TEXT NOT NULL,
  agent_id         TEXT REFERENCES agent(id),
  device_id        TEXT REFERENCES device(id),
  import_run_id    TEXT REFERENCES import_run(id),
  capture_id       TEXT UNIQUE,
  target_memory_id TEXT REFERENCES memory(id) ON DELETE SET NULL,
  action           TEXT NOT NULL DEFAULT 'create',
  title            TEXT NOT NULL,
  body             TEXT NOT NULL,
  kind             TEXT,
  category_keys    TEXT NOT NULL DEFAULT '[]',
  sensitivity      INTEGER,
  expires_at       TEXT,
  confidence       REAL,
  evidence         TEXT,
  purpose          TEXT,
  caller_metadata  TEXT,               -- JSON, inert
  classification   TEXT,               -- JSON proposals + engine
  status           TEXT NOT NULL DEFAULT 'pending',
  created_at       TEXT NOT NULL,
  decided_at       TEXT,
  expires_after    TEXT NOT NULL,      -- created_at + 30 days
  result_memory_id TEXT REFERENCES memory(id) ON DELETE SET NULL
);
CREATE INDEX suggestion_pending ON suggestion(status, created_at DESC);

CREATE TABLE device (
  id                 TEXT PRIMARY KEY,
  name               TEXT NOT NULL,
  model              TEXT NOT NULL,
  signing_public_key BLOB NOT NULL,
  hpke_public_key    BLOB NOT NULL,
  paired_at          TEXT NOT NULL,
  last_seen_at       TEXT,
  last_transport     TEXT,
  revoked_at         TEXT,
  -- v3_device_approvals (ADR-0019, task 5.6):
  approvals_enabled  INTEGER NOT NULL DEFAULT 1,
  doorbell_tag       TEXT              -- set when the phone asks, while approvals are on
);

CREATE TABLE capture_receipt (
  capture_id    TEXT PRIMARY KEY,
  device_id     TEXT NOT NULL REFERENCES device(id),
  received_at   TEXT NOT NULL,
  suggestion_id TEXT NOT NULL REFERENCES suggestion(id)
);

CREATE TABLE import_run (
  id          TEXT PRIMARY KEY,
  source      TEXT NOT NULL,      -- chatgpt | claude | markdown | funes
  created_at  TEXT NOT NULL,
  item_count  INTEGER NOT NULL,
  blocked     INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);  -- schema version, vault id, etc.
-- v0.3: meta('tidy_up_split_prompt') = the extraction prompt version whose one-time clearing of older split
-- dismissals has run (memory processing §9.5).
```

## 3. Migrations
- These are GRDB `DatabaseMigrator`, forward-only and named (`v1_initial`, `v2_…`).
- `v2_remote_access` (v0.1, Phase 4b): adds `agent.cloud_access` (0 for every existing agent), `remote_key_digest` and `remote_key_issued_at`, and the unique index on the digest.
- `v3_device_approvals` (v0.2, task 5.6): adds `device.approvals_enabled` (1 for every existing device) and `doorbell_tag` (empty until the phone asks for it).
- `v4_memory_processing` (v0.3, Phase 6.1; [ADR-0020](decisions/0020-atomic-extraction-for-every-source.md), [ADR-0021](decisions/0021-daily-tidy-up.md)): `memory.trust` (`trusted` for every existing memory except `agent_write` ones, which are `untrusted`) and `memory.reconciled_version` (null); `suggestion.target_memory_version`, `group_id`, `intent`, `outside_scope`, and the `split` status; tables `suggestion_target`, `suggestion_group`, `processing_job`, `undo_entry`, `tidy_up_run` and `tidy_up_dismissal`; `provenance.related_memory_id` and `engine`. Fields as in the [domain model](../domain/domain-model.md#suggestion). The physical DDL is `Schema.v4` in FunesCore. Suggestions pending before it have no target version, so apply only checks that their target is still active.
- `v5_overview_indexes` (v0.4, Phase 7 task 7.2; [ADR-0025](decisions/0025-vault-overview-and-iphone-cache.md)): `VaultOverview` took 86–105 ms on the 10,000-memory benchmark vault without indexes, so five indexes, each carrying the columns its query groups by so the scans don't visit rows that hold memory text and candidate snapshots: `memory_created` on `memory(created_at, source, source_device_id)`, `memory_status_shape` on `memory(status, sensitivity, kind, id)`, `disclosure_delivered` on `disclosure(delivered_at, agent_id)` where `delivered_at` is set, `disclosure_created` on `disclosure(created_at, agent_id, status, reason)`, and `disclosure_item_shape` on `disclosure_item(disclosure_id, sensitivity, category_key)`. No data changes. With them it takes about 12 ms for 30 days, 14 ms for 12 weeks and 36 ms for 12 months (up to about 45 ms while the Mac is busy).
- Before running pending migrations: make an online backup to `Backups/pre-<migration>-<date>.sqlite`.
- Each migration has a test: open a fixture database created by the previous version, migrate it, and check the data and invariants.
- Downgrades aren't supported. An older app version that finds a newer schema refuses to open the vault, shows "Update Funes", and never writes to it.

## 4. Invariants enforced in code (and tested)
- **Categories:** a memory always has at least one `memory_category` row, enforced in the store API, since SQLite can't express it. A memory's categories are read in category order (`sort_order`, then key); the first is its primary category (the `category` of a bundle item).
- **Versioning:** `version` increments in the same transaction as any field change. `updated_at` is set at the same time.
- **Disclosure items:** written only in delivery transactions.
- **Captures:** `capture_receipt` is inserted in the same transaction as its suggestion.
- **Purging** a deleted memory removes its FTS rows, embedding and provenance (cascade). `disclosure_item` rows keep the memory id for Activity labelling, shown as "(deleted memory)".
- **Purging (v0.3)** also removes the memory's `undo_entry` rows, the text of the piece it was saved from, and the source text of the `suggestion_group` that piece belongs to (with the original row's title and body), so no copy of its text outlives it (FR-V-04). Delete Now does the same at once.
- **Auto-apply (v0.3):** each automatic change, its `undo_entry`, its provenance and the watermark update are written in one transaction, after re-checking every involved memory's version.

## 5. Maintenance jobs
| Job | When | What |
|---|---|---|
| Purge deleted | launch, then daily | Hard-delete memories deleted more than 30 days ago |
| Expire suggestions | launch, then hourly | `pending` → `expired` after 30 days; delete expired ones after 7 more days, except while a capture receipt still points at them (receipts keep captures idempotent for 90 days) |
| Expire disclosures | every minute while any are pending | needs_approval older than 15 min → denied |
| Re-embed | on change; when the bundled model version changes; v0.3, when the user adds a provider embedding model (batched, resumable, with progress; see [model providers §7](model-providers.md#7-choosing-a-provider-embedding-model)) | Bundled: write vectors for the new `model_id`, switch when complete, delete old vectors. Provider (second index): write vectors for memories within the cloud limit; delete them when the limit drops, a memory's sensitivity rises above it, or the provider model is removed |
| Processing jobs (v0.3) | after every vault change and every minute, one at a time; `running` ones requeued at launch | New memories processing of queued inputs ([memory processing §5.2](../domain/memory-processing.md#52-which-inputs-phase-6)): until 6a, classification of Mac and iPhone captures. Retries after 30 s, 2, 8 and 32 min, then `failed`. Finished jobs deleted after 30 days (daily) |
| Daily tidy-up (v0.3) | daily at the user's time (`NSBackgroundActivityScheduler`), on demand, or on the next launch or wake after a missed run; only while on | [Memory processing §9](../domain/memory-processing.md#9-daily-tidy-up) |
| Undo log cleanup (v0.3) | daily | Delete `undo_entry` rows past 30 days; drop source text of fully decided suggestion groups |
| Backup | daily, and before migrations | Keep the last 7 |
| Activity compaction | launch, every 6 h, above 8 MB | Retention per FR-L-03 |
| Receipt cleanup | daily | Delete capture receipts older than 90 days |
| Integrity check | weekly | `PRAGMA quick_check`. On failure, notify and offer to restore from a backup |

## 6. iPhone storage
- **App Group container:** `capture-queue.sqlite` (the capture queue), with file protection `completeUntilFirstUserAuthentication`.
- **Keychain:** device signing and HPKE keys, and the pairing record (Mac public keys, ids, addresses).
- **App Group container (v0.4):** `overview.json`, the last `overview.get` answer for each range (counts, dates and agent names; no memory text or titles), with the same file protection, for Home and the widgets ([ADR-0025](decisions/0025-vault-overview-and-iphone-cache.md); [companion protocol §6.1](companion-protocol.md#61-overview-cache-phone-v04)).
- **No** other vault data. Search results and memory details live only in memory while on screen.
- **Demo vault:** a read-only JSON resource in the app bundle.
