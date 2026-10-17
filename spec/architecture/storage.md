# Storage

## 1. Files on disk (Mac)
Everything lives under `~/Library/Application Support/FunesVault/`, in a 0700 folder with 0600 files owned by the user. Loading **fails closed** on a wrong owner or mode, a symlink (`O_NOFOLLOW`), or an oversize file. This is EK Bridge's file-safety pattern.

| Path | Contents | Notes |
|---|---|---|
| `vault.sqlite` (+ `-wal`, `-shm`) | Memories, categories, suggestions, agents, access, disclosures, devices, receipts, provenance, embeddings, FTS | GRDB `DatabasePool`, WAL mode |
| `agent-keys/<agentId>.key` | The agent's MCP key, bare with no newline | Written once, never read back except by **Copy key**. Deleted on removal |
| `activity/activity.jsonl` | Activity log, append-only | BridgeUI `ActivityStore` (copied from EK Bridge); `fsync` per row |
| `mcp-endpoint.json` | `{"version":1,"url","port","pid","startedAt"}` | Only while listening |
| `Backups/vault-YYYYMMDD-HHMM.sqlite` | Online backups (GRDB `backup(to:)`) | Daily, keep 7; also before each migration |
| `companion/` (v0.2) | Replay-nonce cache snapshot (optional) | Keys live in the Keychain, not here |

- **Keychain:** Mac signing and HPKE keys, and **AI provider API keys** (service `com.funesvault.provider`), all with `ThisDeviceOnly` accessibility.
- **AI provider settings** (provider definitions without keys, the per-task model choice, the cloud sensitivity limit, usage counters) live in user defaults. They're never exported.
- **User defaults:** UI preferences, the hotkey, ports, iPhone access modes, update settings, setup checklist state.
- **Nothing** lives in `/tmp`. Unlike EK Bridge, there's no file transport.

**Encryption at rest:** relies on FileVault in v0.1. Optional SQLCipher is an [open question](../plans/open-questions.md).

## 2. Schema (v1)
SQLite with `PRAGMA foreign_keys = ON`, `journal_mode = WAL` and `synchronous = NORMAL`. Times are stored as ISO-8601 UTC text in Swift `Date` columns via GRDB. Ids are UUID text.

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
  id                TEXT PRIMARY KEY,
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
  title, body, content='memory', content_rowid='rowid',
  tokenize='porter unicode61 remove_diacritics 2'
);
-- triggers memory_ai / memory_ad / memory_au insert/delete/update memory_fts rows

CREATE TABLE embedding (           -- ADR-0016: about 15 MB of vectors at 10,000 memories
  memory_id    TEXT NOT NULL REFERENCES memory(id) ON DELETE CASCADE,
  model_id     TEXT NOT NULL,      -- v0.1: "bge-small-en-v1.5/coreml-fp16" (384 dims); later e.g. "openai/text-embedding-3-small"
  dims         INTEGER NOT NULL,
  vector       BLOB NOT NULL,      -- Float32 little-endian, L2-normalized
  content_hash TEXT NOT NULL,      -- SHA-256 of the embedded text
  PRIMARY KEY (memory_id, model_id)  -- two models coexist only while re-embedding
);
-- meta('active_embedding_model') names the model search uses; meta('embedding_thresholds') holds per-model thresholds (JSON)

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
  removed_at         TEXT
);
CREATE UNIQUE INDEX agent_active_name ON agent(name) WHERE removed_at IS NULL;
CREATE UNIQUE INDEX agent_key_digest ON agent(key_digest) WHERE key_digest IS NOT NULL;

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
  PRIMARY KEY (agent_id, category_key)
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
  revoked_at         TEXT
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
```

## 3. Migrations
- These are GRDB `DatabaseMigrator`, forward-only and named (`v1_initial`, `v2_…`).
- Before running pending migrations: make an online backup to `Backups/pre-<migration>-<date>.sqlite`.
- Each migration has a test: open a fixture database created by the previous version, migrate it, and check the data and invariants.
- Downgrades aren't supported. An older app version that finds a newer schema refuses to open the vault, shows "Update Funes", and never writes to it.

## 4. Invariants enforced in code (and tested)
- **Categories:** a memory always has at least one `memory_category` row, enforced in the store API, since SQLite can't express it.
- **Versioning:** `version` increments in the same transaction as any field change. `updated_at` is set at the same time.
- **Disclosure items:** written only in delivery transactions.
- **Captures:** `capture_receipt` is inserted in the same transaction as its suggestion.
- **Purging** a deleted memory removes its FTS rows, embedding and provenance (cascade). `disclosure_item` rows keep the memory id for Activity labelling, shown as "(deleted memory)".

## 5. Maintenance jobs
| Job | When | What |
|---|---|---|
| Purge deleted | launch, then daily | Hard-delete memories deleted more than 30 days ago |
| Expire suggestions | launch, then hourly | `pending` → `expired` after 30 days; delete expired ones after 7 more days |
| Expire disclosures | every minute while any are pending | needs_approval older than 15 min → denied |
| Re-embed | on change; when the bundled model version changes; later, when the user switches the embedding model (batched, resumable, with progress; see [model providers §7](model-providers.md#7-switching-the-embedding-model)) | Write vectors for the new `model_id`; switch `active_embedding_model` atomically when complete; delete old vectors |
| Backup | daily, and before migrations | Keep the last 7 |
| Activity compaction | launch, every 6 h, above 8 MB | Retention per FR-L-03 |
| Receipt cleanup | daily | Delete capture receipts older than 90 days |
| Integrity check | weekly | `PRAGMA quick_check`. On failure, notify and offer to restore from a backup |

## 6. iPhone storage
- **App Group container:** `capture-queue.sqlite` (the capture queue), with file protection `completeUntilFirstUserAuthentication`.
- **Keychain:** device signing and HPKE keys, and the pairing record (Mac public keys, ids, addresses).
- **No** vault data. Search results and memory details live only in memory while on screen.
- **Demo vault:** a read-only JSON resource in the app bundle.
