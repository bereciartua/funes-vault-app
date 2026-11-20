# Storage

## 1. Files on disk (Mac)
Everything lives under `~/Library/Application Support/FunesVault/`, in a 0700 folder with 0600 files owned by the user. Loading **fails closed** on a wrong owner or mode, a symlink (`O_NOFOLLOW`), or an oversize file. This is EK Bridge's file-safety pattern.

| Path | Contents | Notes |
|---|---|---|
| `vault.sqlite` (+ `-wal`, `-shm`) | Memories, categories, suggestions, agents, access, disclosures, devices, receipts, provenance, embeddings, FTS, the profile (v0.5), learned facts (v0.10) | GRDB `DatabasePool`, WAL mode |
| `agent-keys/<agentId>.key` | The agent's MCP key, bare with no newline | Written once, never read back except by **Copy key**. Deleted on removal |
| `agent-keys/<agentId>.remote.key` | The agent's Remote Access token (`fns_mcpr_v1_`), bare | Only with Allow cloud access. Read back only by **Copy Remote Token…**. Replaced by **Reset Remote Token…**; deleted when cloud access is turned off or the agent is removed ([ADR-0018](decisions/0018-remote-access-in-v0.1.md)) |
| `remote-connections.json` | Remote Access OAuth state: connected cloud apps (agent id, app name, OAuth client id, MCP URL, SHA-256 digests of the access, refresh and recently rotated refresh tokens, expiry and use times) and registered OAuth clients (`dcr_`, and `cfg_` with the digest of its `fns_ocs_v1_` secret) | BridgeKitRemote's `OAuthStore`: written atomically with fsync, fails closed (a wrong owner, mode, size or content makes OAuth unavailable and the file is never overwritten). No token in the clear. Never exported |
| `activity/activity.jsonl` | Activity log, append-only | BridgeUI `ActivityStore` (copied from EK Bridge); `fsync` per row |
| `mcp-endpoint.json` | `{"version":1,"url","port","pid","startedAt"}` | Only while listening |
| `instance.lock` | Empty; an exclusive `flock` while a copy of the app has this folder open | One copy at a time on a vault: a copy that can't take the lock brings the running one forward and quits before opening anything (a relaunch first waits for the copy it names). Erase All Data leaves it |
| `restore-pending.json`, `erase-pending` | A restore or Erase All Data asked for, carried out at the next launch before anything opens | Removed when it's been carried out; the app then says how it went |
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
-- cloud limit (search uses it only then). The choice and Calibrate's thresholds live in user defaults (Settings ▸ AI ▸ Features ▸ Search index).

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

-- v6_profile (v0.5, ADR-0026): the profile fields each agent's request_memory answers carry.
CREATE TABLE access_profile_field (
  agent_id TEXT NOT NULL REFERENCES agent(id) ON DELETE CASCADE,
  field    TEXT NOT NULL CHECK (field IN ('name','pronouns','languages','location','time_zone','occupation')),
  PRIMARY KEY (agent_id, field)
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
  delivered_at             TEXT,
  -- v6_profile (ADR-0026):
  profile_fields_sent      TEXT NOT NULL DEFAULT '[]'    -- JSON [field]; names only, never values
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

-- v6_profile (v0.5, ADR-0026): "About you". One row, every field optional; not a memory.
CREATE TABLE profile (
  id              INTEGER PRIMARY KEY CHECK (id = 1),
  given_name      TEXT,
  family_name     TEXT,
  preferred_name  TEXT,
  pronouns        TEXT,
  languages       TEXT NOT NULL DEFAULT '[]',          -- JSON [BCP 47 tag], ordered
  location        TEXT,
  time_zone       TEXT NOT NULL DEFAULT 'automatic',   -- an IANA id, or 'automatic' (the Mac's)
  occupation      TEXT,
  updated_at      TEXT
);

-- v7_memory_revisions (v0.5, ADR-0027): the version each change replaced. Never exported.
CREATE TABLE memory_revision (
  memory_id      TEXT NOT NULL REFERENCES memory(id) ON DELETE CASCADE,
  version        INTEGER NOT NULL,                     -- the version this state was
  title          TEXT NOT NULL,
  body           TEXT NOT NULL,
  kind           TEXT NOT NULL,
  category_keys  TEXT NOT NULL DEFAULT '[]',           -- JSON [category key]
  sensitivity    INTEGER NOT NULL,
  status         TEXT NOT NULL,
  expires_at     TEXT,
  replaced_at    TEXT NOT NULL,
  replaced_by    TEXT NOT NULL,                        -- the change's actor, as in provenance
  PRIMARY KEY (memory_id, version)
);
CREATE INDEX memory_revision_replaced ON memory_revision(replaced_at);

-- v9_facts (v0.10, ADR-0032; memory processing §11): learned facts. Owner side only: agent retrieval never reads
-- these tables. No start or end dates are stored: episodes are derived from fact_evidence when needed.
CREATE TABLE entity (
  id          TEXT PRIMARY KEY,
  kind        TEXT NOT NULL CHECK (kind IN ('person','organization','place','thing')),
  is_you      INTEGER NOT NULL DEFAULT 0,                -- exactly one row; never has a name or alias
  name        TEXT,                                      -- shown name; inferred ones go with their last supporting memory
  group_predicate TEXT, group_label TEXT, group_count INTEGER,  -- a role group ("your sisters") until members are named
  deceased    INTEGER NOT NULL DEFAULT 0,                -- learned from memories ("my late grandmother") or set by the user
  hidden      INTEGER NOT NULL DEFAULT 0,
  manual      INTEGER NOT NULL DEFAULT 0,                -- created by the user: never purged with memories
  tombstone   INTEGER NOT NULL DEFAULT 0,                -- 1: no memory supports it, but a manual entry, override or
                                                         -- correction references it (§4); name is NULL unless the user typed it
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);
CREATE UNIQUE INDEX entity_you ON entity(is_you) WHERE is_you = 1;

CREATE TABLE entity_alias (
  id          TEXT PRIMARY KEY,
  entity_id   TEXT NOT NULL REFERENCES entity(id) ON DELETE CASCADE,
  alias       TEXT,                                      -- as written; NULL in a tombstone unless the user typed it
  normalized  TEXT NOT NULL,                             -- case and accents folded; legal suffixes for organizations
  manual      INTEGER NOT NULL DEFAULT 0,                -- typed by the user
  confirmed   INTEGER NOT NULL DEFAULT 0                 -- confirmed by the user (To check, Merge With…): kept in a tombstone
);
CREATE INDEX entity_alias_normalized ON entity_alias(normalized);
CREATE INDEX entity_alias_entity ON entity_alias(entity_id);

CREATE TABLE alias_evidence (
  alias_id       TEXT NOT NULL REFERENCES entity_alias(id) ON DELETE CASCADE,
  memory_id      TEXT NOT NULL REFERENCES memory(id) ON DELETE CASCADE,
  memory_version INTEGER NOT NULL,
  span_start     INTEGER NOT NULL, span_end INTEGER NOT NULL,   -- Unicode scalar offsets into the memory's text at that version
  quote          TEXT NOT NULL,
  sensitivity    INTEGER NOT NULL,                       -- the memory's at that version
  trust          TEXT NOT NULL CHECK (trust IN ('trusted','untrusted')),
  run_id         TEXT REFERENCES facts_run(id) ON DELETE SET NULL,
  call_group     TEXT NOT NULL DEFAULT '',               -- v10: the call that gave it; a re-read replaces only its own group's
  source         TEXT NOT NULL DEFAULT 'model' CHECK (source IN ('model','code')),   -- v10: code = a name found without a model; never in a roster
  read_at        TEXT,                                   -- v10: when this reading was made
  first_read_at  TEXT,                                   -- v10: when this memory version first gave the alias (kept by a re-read)
  PRIMARY KEY (alias_id, memory_id, memory_version, span_start, call_group)
);
CREATE INDEX alias_evidence_memory ON alias_evidence(memory_id);

-- memory gains original_source TEXT: the source a Funes restore found (NULL otherwise). Learned facts read it before
-- `source`, so a restored import stays undated and a restored capture keeps its date; the app shows `source`.

CREATE TABLE fact (
  id          TEXT PRIMARY KEY,
  predicate   TEXT NOT NULL,                             -- a registry key; the subject is always "you" in v0.10
  entity_id   TEXT NOT NULL REFERENCES entity(id) ON DELETE RESTRICT,  -- never cascades: inferred facts are deleted
                                                         -- first, and an entity a manual fact needs is kept as a tombstone
  manual      INTEGER NOT NULL DEFAULT 0,                -- entered by the user; its sensitivity is in manual_override
  tombstone   INTEGER NOT NULL DEFAULT 0,                -- 1: kept only because a manual entry, override or correction
                                                         -- references it; holds its id, predicate and the user's own values
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  UNIQUE (predicate, entity_id)                          -- episodes, qualifiers and status come from evidence
);
CREATE INDEX fact_entity ON fact(entity_id);

-- One evidence table for facts, qualifiers and order edges, from memories and from the user.
CREATE TABLE fact_evidence (
  id             TEXT PRIMARY KEY,
  target_kind    TEXT NOT NULL CHECK (target_kind IN ('fact','qualifier','order')),
  fact_id        TEXT NOT NULL REFERENCES fact(id) ON DELETE CASCADE,
  qualifier      TEXT,                                   -- 'label', 'title', 'kind'… (target_kind 'qualifier')
  other_fact_id  TEXT REFERENCES fact(id) ON DELETE CASCADE,  -- target_kind 'order'
  direction      TEXT CHECK (direction IN ('preceded_by','followed_by')),
  episode_selector       TEXT,                           -- user rows: JSON {lo, hi}, the date range of the episode the
  other_episode_selector TEXT,                           -- user acted on (fact_id's, other_fact_id's); NULL: the fact
  source         TEXT NOT NULL CHECK (source IN ('memory','user')),  -- 'user': a date, order or qualifier the user
                                                         -- entered; it wins over inference
  memory_id      TEXT REFERENCES memory(id) ON DELETE CASCADE,       -- NULL for 'user'
  memory_version INTEGER,
  span_start     INTEGER, span_end INTEGER,              -- NULL for 'user'
  quote          TEXT,                                   -- NULL for 'user'
  asserted       TEXT NOT NULL DEFAULT '{}',  -- JSON as written: {status?, start?, end?, time?, value?, only?, count?, n, written?}:
                                              -- dates as written; `n` the statement's ordinal within the memory (a
                                              -- memory's rows for one statement share it, denials included); `only`
                                              -- the statement's own; `count` on a role group's fact; `written` the day
                                              -- a user row was entered. Hand-overs are derived when read, never stored.
                                              -- On your rows (13c): `at`, the People & history action's stamp
                                              -- (Undo takes the action's rows together); `created` on a manual
                                              -- fact's founding row; `clears_dates` (Clear Dates: your earlier dates
                                              -- on that selector stop counting); `retired_at`, the To check answer
                                              -- that moved or removed the row (it then counts nowhere; Undo clears
                                              -- it). Your later rows supersede your earlier start, end and status
                                              -- for the same episode selector.
  states         INTEGER NOT NULL,                       -- 1: the memory states it; 0: it only mentions it (1 for 'user')
  polarity       TEXT NOT NULL CHECK (polarity IN ('affirmed','denied')),
  sensitivity    INTEGER NOT NULL,                       -- the memory's at that version, or the user's choice
  trust          TEXT NOT NULL CHECK (trust IN ('trusted','untrusted')),  -- 'trusted' for 'user'
  call_group     TEXT,                                   -- NULL for 'user'
  run_id         TEXT REFERENCES facts_run(id) ON DELETE SET NULL,
  CHECK ((source = 'memory') = (memory_id IS NOT NULL AND memory_version IS NOT NULL AND quote IS NOT NULL))
);
CREATE INDEX fact_evidence_fact ON fact_evidence(fact_id, target_kind);
CREATE INDEX fact_evidence_other ON fact_evidence(other_fact_id) WHERE other_fact_id IS NOT NULL;
-- A role group a memory states, with its count when it gives one, is evidence on the group's own fact row, so the
-- group goes with its memory (and a cloud roster shows it only with a sendable memory behind it); a death is a
-- `qualifier` row ('deceased'). A count and a death count from trusted memories only.
CREATE INDEX fact_evidence_memory ON fact_evidence(memory_id, memory_version);

CREATE TABLE mention_decision (
  id             TEXT PRIMARY KEY,
  memory_id      TEXT NOT NULL,                          -- no FK: a user's decision keeps the id after a purge
  memory_version INTEGER,                                -- the model's decisions; NULL for the user's (keyed to the quote)
  mention        TEXT,                                   -- "my sister", "Alex"; NULL once purged
  quote          TEXT,                                   -- the quoted span's text; NULL once purged
  span_start     INTEGER, span_end INTEGER,
  outcome        TEXT NOT NULL CHECK (outcome IN ('entity','group','someone_else','unknown','rejected')),
                                                         -- a user's 'unknown' is To check's Skip (deleted with a purge)
  entity_id      TEXT,                                   -- no FK: a correction outlives an inferred entity
  basis          TEXT NOT NULL,                          -- memory processing §11.4
  source         TEXT NOT NULL CHECK (source IN ('model','user')),
  call_group     TEXT,
  run_id         TEXT REFERENCES facts_run(id) ON DELETE SET NULL,
  created_at     TEXT NOT NULL,
  invalidated_at TEXT                                    -- a dependency changed; the memory is queued again
);
CREATE INDEX mention_decision_memory ON mention_decision(memory_id);

CREATE TABLE decision_dependency (
  decision_id TEXT NOT NULL REFERENCES mention_decision(id) ON DELETE CASCADE,
  kind        TEXT NOT NULL CHECK (kind IN ('memory','fact','entity')),
  ref_id      TEXT NOT NULL,
  ref_version TEXT NOT NULL,                             -- a memory version, or a fact's or entity's updated_at;
                                                         -- kind 'fact' with ref_id 'predicate:<id>' is the number
                                                         -- of that predicate's facts (a new candidate holder).
                                                         -- Checked again when facts are read. Touching a fact
                                                         -- also moves its entity's updated_at (roster tokens).
  PRIMARY KEY (decision_id, kind, ref_id)
);
CREATE INDEX decision_dependency_ref ON decision_dependency(kind, ref_id);

CREATE TABLE facts_asked (                               -- v11: what each model reading was asked knowing
  memory_id      TEXT NOT NULL REFERENCES memory(id) ON DELETE CASCADE,
  memory_version INTEGER NOT NULL,                       -- follows a status-only bump; dropped with a text edit
  call_group     TEXT NOT NULL,
  mention_kind   TEXT NOT NULL CHECK (mention_kind IN ('read','phrase','name','decision')),
                                                         -- read: the model read this version in this group;
                                                         -- phrase: a role phrase; name: a name;
                                                         -- decision: the knowledge a model decision was made with
  mention_key    TEXT NOT NULL,                          -- '' · the phrase's scalar start · the folded name · the decision id
  knowledge      TEXT NOT NULL,                          -- a digest of the holders or candidates as the call saw them (no
                                                         -- name or label, no timestamps, no quotes); a read row: the key
                                                         -- it was made under, x=<extraction key>;r=<recorded predicates>
  asked_at       TEXT NOT NULL,
  PRIMARY KEY (memory_id, memory_version, call_group, mention_kind, mention_key)
);
-- processing_job gains generation INTEGER NOT NULL DEFAULT 0 (v11): bumped by every enqueue of a facts job, so one
-- asked for while it runs goes back to the queue when it finishes, whatever its outcome. It gains exempt_version
-- INTEGER (v12): a job of the first backfill, the memory version whose full read skips the daily cap; cleared when
-- the job ends. It gains normal_version INTEGER (v13): the version an insert or a title or body edit asked it to read;
-- only a first read of that version is normal work, everything else the job does is in the cap's low-priority share.

CREATE TABLE manual_override (
  id          TEXT PRIMARY KEY,
  target_kind TEXT NOT NULL CHECK (target_kind IN ('entity','alias','fact','qualifier','date','status','order')),
  target_id   TEXT NOT NULL,                             -- no FK: it outlives what it corrects
  field       TEXT NOT NULL,                             -- 'name', 'kind', 'predicate', 'label', 'deceased', 'rejected',
                                                         -- 'merged_into', 'not_same' (Merge With…, Not the Same),
                                                         -- 'hidden' (People & history's list only)…
                                                         -- 'kind': {kind, previous_kind}; entity.kind changes with it
  value       TEXT,                                      -- JSON (for 'merged_into' and 'not_same': the other entity's id)
  episode_selector TEXT,                                 -- JSON {lo, hi}: the target episode's date range when the user
                                                         -- acted; NULL when it targets the whole fact
  sensitivity INTEGER NOT NULL,                          -- the user's choice; decides whether it may be sent
  memory_id   TEXT,                                      -- a correction made from a memory ("Not this")…
  quote       TEXT,                                      -- …keyed to its quoted span; NULL once purged. NULL memory_id:
                                                         -- it applies everywhere
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);
CREATE INDEX manual_override_target ON manual_override(target_kind, target_id);
-- An override on an order edge carries the edge itself in `value` ({before, after, before_selector?, after_selector?}:
-- both endpoints' fact ids and episode selectors), so it survives when the memory evidence that stated the edge is
-- removed: a correction-owned order, with no quote. `not_same` and `merged_into` hold the other entity's id.

-- Local rows only: the qualification records ship with the app as Resources/facts-qualification.json, with the
-- same fields (a record there pools predicates and uses). A row here is the two-week review's off-switch (passed = 0)
-- for one predicate and use of one record; a local row never turns anything on. Neither is exported, and Remove
-- learned facts doesn't touch them.
CREATE TABLE fact_qualification (
  predicate        TEXT NOT NULL,
  use              TEXT NOT NULL CHECK (use IN ('recorded','linked','timeline','attributes','bridges')),
  basis            TEXT NOT NULL DEFAULT '',             -- 'sole_known' for that attribute gate; '' for every other
  model            TEXT NOT NULL,                        -- "<provider>/<model id>", the full id (never an alias)
  prompt_version   TEXT NOT NULL,                        -- the call group's
  registry_version TEXT NOT NULL,                        -- "<label>-<digest>": the registry but uses lists and notes
  adapter          TEXT NOT NULL,                        -- "claude-code/1;effort=low": provider, revision, settings
  batching         TEXT NOT NULL,                        -- "one-memory;pipeline=1": the pipeline's revision
  gate             TEXT NOT NULL,                        -- the gate measured, and its result
  passed           INTEGER NOT NULL,                     -- 0: turned off (a failed gate, or the two-week review)
  recorded_at      TEXT NOT NULL,
  PRIMARY KEY (predicate, use, basis, model, prompt_version, registry_version, adapter, batching)
);

CREATE TABLE facts_run (
  id               TEXT PRIMARY KEY,
  kind             TEXT NOT NULL CHECK (kind IN ('backfill','incremental','reread','reconciliation')),
  call_group       TEXT NOT NULL,
  registry_version TEXT NOT NULL,                        -- the fingerprint, as a qualification record names it
  prompt_version   TEXT NOT NULL,
  engine           TEXT NOT NULL,
  cap_exempt       INTEGER NOT NULL DEFAULT 0,           -- the first backfill only
  resume_after     INTEGER,                              -- unused: the backfill's marked jobs are its resume point
  counts           TEXT NOT NULL DEFAULT '{}',           -- JSON: memories, calls, entities, facts, decisions
  started_at       TEXT NOT NULL,
  finished_at      TEXT,
  error            TEXT
);
-- meta('facts_revision') = a counter, +1 whenever learned facts, decisions or corrections change what search or
-- answers would show (the held-answer key, companion protocol status.get). meta('facts_epoch') = a UUID, set by the
-- migration and again on every restore, so a restore can't repeat a revision: status.get's factsRevision is
-- "<epoch>.<counter>". meta('facts_backfill') = the first backfill's state once started (JSON: started, memories and
-- calls counted, each group's engine and the cloud limit shown, paused, changed, finished, ended done; `removed`, left by an older
-- version, reads as none): one exemption in total, covering both call groups, not one per group. Remove learned facts
-- deletes it, so the next turn-on offers the backfill again; a restore keeps the live vault's, or its absence.

CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);  -- schema version, vault id, etc.
-- v0.5: meta('keep_revisions') = '0' once the user turned earlier versions off; absent means on.
-- v0.3: meta('tidy_up_split_prompt') = the extraction prompt version whose one-time clearing of older split
-- dismissals has run (memory processing §9.5).
```

## 3. Migrations
- These are GRDB `DatabaseMigrator`, forward-only and named (`v1_initial`, `v2_…`).
- `v2_remote_access` (v0.1, Phase 4b): adds `agent.cloud_access` (0 for every existing agent), `remote_key_digest` and `remote_key_issued_at`, and the unique index on the digest.
- `v3_device_approvals` (v0.2, task 5.6): adds `device.approvals_enabled` (1 for every existing device) and `doorbell_tag` (empty until the phone asks for it).
- `v4_memory_processing` (v0.3, Phase 6.1; [ADR-0020](decisions/0020-atomic-extraction-for-every-source.md), [ADR-0021](decisions/0021-daily-tidy-up.md)): `memory.trust` (`trusted` for every existing memory except `agent_write` ones, which are `untrusted`) and `memory.reconciled_version` (null); `suggestion.target_memory_version`, `group_id`, `intent`, `outside_scope`, and the `split` status; tables `suggestion_target`, `suggestion_group`, `processing_job`, `undo_entry`, `tidy_up_run` and `tidy_up_dismissal`; `provenance.related_memory_id` and `engine`. Fields as in the [domain model](../domain/domain-model.md#suggestion). The physical DDL is `Schema.v4` in FunesCore. Suggestions pending before it have no target version, so apply only checks that their target is still active.
- `v5_overview_indexes` (v0.4, Phase 7 task 7.2; [ADR-0025](decisions/0025-vault-overview-and-iphone-cache.md)): `VaultOverview` took 86–105 ms on the 10,000-memory benchmark vault without indexes, so five indexes, each carrying the columns its query groups by so the scans don't visit rows that hold memory text and candidate snapshots: `memory_created` on `memory(created_at, source, source_device_id)`, `memory_status_shape` on `memory(status, sensitivity, kind, id)`, `disclosure_delivered` on `disclosure(delivered_at, agent_id)` where `delivered_at` is set, `disclosure_created` on `disclosure(created_at, agent_id, status, reason)`, and `disclosure_item_shape` on `disclosure_item(disclosure_id, sensitivity, category_key)`. No data changes. With them it takes about 12 ms for 30 days, 14 ms for 12 weeks and 36 ms for 12 months (up to about 45 ms while the Mac is busy).
- `v6_profile` (v0.5, [ADR-0026](decisions/0026-about-you-profile.md)): the `profile` table (no row until the user first saves About You), `access_profile_field` with `name` for every agent not removed, and `disclosure.profile_fields_sent` (`[]` for every existing request).
- `v7_memory_revisions` (v0.5, [ADR-0027](decisions/0027-memory-revisions.md)): the `memory_revision` table and its index. Nothing to backfill.
- `v8_tidy_up_scope` (v0.5.1, [memory processing §9.7](../domain/memory-processing.md#97-tidy-up-on-one-memory)): `tidy_up_run.scope`, `all` (every existing run) or `memory` for Tidy Up on one memory.
- `v9_facts` (v0.10, Phase 13a.1; [ADR-0032](decisions/0032-facts-about-you.md), [memory processing §11](../domain/memory-processing.md#11-facts-about-you)): the tables `entity` (with the one *you* row), `entity_alias`, `alias_evidence`, `fact`, `fact_evidence` (one evidence table for facts, qualifiers and order edges), `mention_decision`, `decision_dependency`, `manual_override`, `fact_qualification` and `facts_run`, and their indexes; `processing_job` gains kind `facts`, `memory_version` and `call_group` (null for other kinds), so a job is one committed memory version in one call group (the table is rebuilt for its CHECK, and its unique index becomes `(subject, kind, COALESCE(call_group, ''))`); `memory.original_source`; the *you* entity; `meta('facts_epoch')` gets a new UUID. Fields as in the [domain model](../domain/domain-model.md#learned-facts-v010). Nothing to backfill: the tables stay empty, apart from *you*, until the user starts the first backfill.
- `v10_alias_provenance` (v0.10, Phase 13a.2; [memory processing §11.3](../domain/memory-processing.md#113-the-facts-task)): `alias_evidence` gains `call_group` (which call gave the alias, so re-reading one call group replaces only that group's evidence: the people call's named things and the work call's employers can be the same organization), `source` (`model` · `code`: names found without a model, which never reach a roster), and `read_at` and `first_read_at` (when a reading was made, and when the memory version first gave the alias: a one-word name read before a namesake was known by it reads as ambiguous). The key gains `call_group`, so the table is rebuilt. `entity_alias` gains `confirmed_at`: when the user confirmed or typed the alias, which dates it the same way. Nothing to backfill: it has no rows before the first backfill.
- `v11_facts_asked` (v0.10, Phase 13a.2; [memory processing §11.3](../domain/memory-processing.md#113-the-facts-task)): the table `facts_asked`, what each model reading was asked knowing, so reconciliation asks again only what changed and revalidates the rest in code; `processing_job.generation`. Since the backfill step, `facts_asked` rows are exported with their memories (§5.2). Nothing to backfill.
- `v12_facts_backfill` (v0.10, Phase 13a.2; [memory processing §11.3](../domain/memory-processing.md#113-the-facts-task), FR-F-03): `processing_job.exempt_version`, the first backfill's marked jobs; `facts_asked` rows other than `read` are deleted, since they held names and labels as plain text (now digests). Nothing to backfill.
- `v13_facts_priority` (v0.10, before 13e; [memory processing §11.3](../domain/memory-processing.md#113-the-facts-task)): `processing_job.normal_version`, for low-priority work's share of the daily cap. Nothing to backfill: existing jobs are low-priority.
- Before running pending migrations: make an online backup to `Backups/pre-<migration>-<date>.sqlite`.
- Each migration has a test: open a fixture database created by the previous version, migrate it, and check the data and invariants.
- Downgrades aren't supported. An older app version that finds a newer schema refuses to open the vault, shows "Update Funes", and never writes to it.

## 4. Invariants enforced in code (and tested)
- **Categories:** a memory always has at least one `memory_category` row, enforced in the store API, since SQLite can't express it. A memory's categories are read in category order (`sort_order`, then key); the first is its primary category (the `category` of a bundle item).
- **Versioning:** `version` increments in the same transaction as any field change. `updated_at` is set at the same time. From v0.5 the state it replaces is written to `memory_revision` in that transaction too, unless earlier versions are off (`MemoryStore.update` and `setStatus` are the only places a version changes).
- **Disclosure items:** written only in delivery transactions.
- **Captures:** `capture_receipt` is inserted in the same transaction as its suggestion.
- **Purging** a deleted memory removes its FTS rows, embedding and provenance (cascade). `disclosure_item` rows keep the memory id for Activity labelling, shown as "(deleted memory)".
- **Purging (v0.3)** also removes the memory's `undo_entry` rows, the text (title, body, evidence) of every suggestion it was saved from or that names it as a target or source, grouped or not and whatever its status (a pending one is closed as rejected, since it can no longer be applied), and the source text of the `suggestion_group` a saved piece belongs to (with the original row's title and body), so no copy of its text outlives it (FR-V-04). The text goes before the row does, since the delete nulls `result_memory_id` and `target_memory_id`. Delete Now does the same at once.
- **Purging (v0.5)** also removes the memory's earlier versions (cascade).
- **Purging (v0.10, learned facts;** [memory processing §11.8](../domain/memory-processing.md#118-keeping-it-right)**)** also removes, in the same transaction, every copy of a name, label, qualifier or quote that only that memory supported, so none outlives its last supporting memory (FR-V-04):
  - its `alias_evidence` and memory `fact_evidence` rows (cascade) and its model decisions;
  - then every inferred alias, fact and entity left with no supporting memory, names and labels included;
  - any undo data holding them;
  - **what the user made stays:** an entity or fact the user created (`manual`), or that a manual entry, a user evidence row, an override or a correction references, is never deleted (`fact` → `entity` doesn't cascade). With no memory left supporting it, it becomes a **tombstone** (`tombstone` = 1) holding its id, its predicate, the user's own values, and the normalised alias the user confirmed or typed; inferred names, aliases and quotes go. A tombstone re-attaches when a memory again supports the same predicate and normalised alias;
  - a user's `mention_decision` or a `manual_override` made from that memory loses its `mention` and `quote` and keeps its memory, entity and fact ids. It holds again only through an identity-preserving restore (a Funes export restored as active memories, §5.2), never because the same text comes back another way.

  Delete Now does the same at once. **Remove learned facts** deletes every inferred row (memory evidence, aliases, model decisions and their dependencies, inferred entities and facts, runs, the first backfill's state) and keeps manual entries, user evidence, corrections, the tombstones they need (made as a purge makes them) and the *you* entity. It doesn't touch qualification records or off-switches. Learning turns off first, and once no facts job is running, every facts job (the sweep it queues included) goes in the same transaction. It writes a `facts_removed` Activity row with counts only.
- **Learned facts (v0.10):** the Facts task applies a memory's results in one transaction, only if the memory's version and every roster entry the call used are unchanged; `meta('facts_revision')` is incremented in that transaction, and in any correction's or purge's that changes what search or answers would show.
- **Auto-apply (v0.3):** each automatic change, its `undo_entry`, its provenance and the watermark update are written in one transaction, after re-checking every involved memory's version.

## 5. Maintenance jobs
| Job | When | What |
|---|---|---|
| Purge deleted | launch, then daily | Hard-delete memories deleted more than 30 days ago |
| Expire suggestions | launch, then hourly | `pending` → `expired` after 30 days; delete expired ones after 7 more days, except while a capture receipt still points at them (receipts keep captures idempotent for 90 days) |
| Expire disclosures | every minute while any are pending | needs_approval older than 15 min → denied |
| Re-embed | on change; when the bundled model version changes; v0.3, when the user adds a provider embedding model (batched, resumable, with progress; see [model providers §7](model-providers.md#7-choosing-a-provider-embedding-model)) | Bundled: write vectors for the new `model_id`, switch when complete, delete old vectors. Provider (second index): write vectors for memories within the cloud limit; delete them when the limit drops, a memory's sensitivity rises above it, or the provider model is removed |
| Processing jobs (v0.3) | after every vault change and every minute, one at a time; `running` ones requeued at launch | New memories processing of queued inputs ([memory processing §5.2](../domain/memory-processing.md#52-which-inputs-phase-6)): until 6a, classification of Mac and iPhone captures. Retries after 30 s, 2, 8 and 32 min, then `failed`. Finished jobs deleted after 30 days (daily), except facts jobs while their memory is active or archived (one row per memory and call group, which puts a memory in the facts lane's catch-up; a done job whose read the guardrails refused keeps `engine = 'code:refused'`) |
| Daily tidy-up (v0.3) | daily at the user's time (`NSBackgroundActivityScheduler`), on demand, or on the next launch or wake after a missed run; only while on | [Memory processing §9](../domain/memory-processing.md#9-daily-tidy-up) |
| Undo log cleanup (v0.3) | daily | Delete `undo_entry` rows past 30 days; drop source text of fully decided suggestion groups; v0.5: delete earlier versions past 90 days, and each memory's oldest beyond 50 |
| Facts jobs (v0.10) | with processing jobs, in their low-priority lane: paused while New memories or tidy-up jobs wait (queued, waiting for a retry, or running) or a tidy-up run is open | [Memory processing §11.3](../domain/memory-processing.md#113-the-facts-task): one `facts` job per memory and call group (`memory_version` is the newest asked for), only while *Learn from memories* is on, and one reconciliation sweep (no call group), queued by any change to learned facts once a model reading exists and run after the memories' jobs. Not counted in the Inbox's waiting figure. The first backfill's jobs are marked (`exempt_version`) and are its resume point; at launch and on every Facts settings change the catch-up queues what the model should read and hasn't |
| Backup | daily, and before migrations | Keep the last 7 |
| Activity compaction | launch, every 6 h, above 8 MB | Retention per FR-L-03 |
| Receipt cleanup | daily | Delete capture receipts older than 90 days |
| Integrity check | weekly | `PRAGMA quick_check`. On failure, notify and offer to restore from a backup |

### 5.1 Restore from Backup
Restoring brings back memories, never credentials or access settings ([security](security-and-privacy.md) T38). A backup holds the agents' key and remote-token digests, their access and the paired devices as they were when it was taken, and authentication trusts the digests in the database. Restoring it as is would let back in a key, token or device removed or reset since, and widen access narrowed since.

So at the next launch, before the vault opens (`VaultStore.restoreBackup`, `RestoreAccess`):
1. The current vault is saved as a self-contained `Backups/pre-restore-…` backup. It's never written again: a scratch copy of it (`vault.sqlite.restoring-current`) is what gets migrated and read. A current vault that can't be read (often the reason to restore) is kept instead as its files are, WAL included, under the same name, and counts as no current vault in step 4.
2. The chosen backup is copied in as `vault.sqlite.restoring` (leftovers of an earlier attempt, journals included, are deleted first) and migrated to this version's schema. A backup from a newer version is refused, and the vault is left as it was.
3. In one transaction on the copy, if both are the same vault (`meta.vault_id`), the current vault's state replaces the backup's:
   - agents (keys, remote tokens, cloud access, pause, names, removal);
   - their access, category rules and profile fields;
   - the never-share categories;
   - paired devices (revocation, approvals, doorbell tag).

   Agents and devices added since the backup are kept, so their keys and pairings keep working. Categories the backup lacks come along, because dropping an allow rule would widen an allow list (an empty one allows every category). A category deleted since comes back with the backup's memories, but its rules can't be rebuilt (deleting it moved its memories and their denies elsewhere), so every agent is denied it until the user decides.
4. Without a current vault, when it can't be read or migrated (a newer version's is still refused, as in step 2), or when the backup is another vault's, nothing can be carried forward. Every agent is removed (keys, remote tokens and access cleared) and every device revoked, so they're set up again.
5. Either way, requests waiting in the backup (`needs_approval`, `approved`) are denied with `approval_expired`, so an approval can't be answered or delivered a second time.
6. The current vault's WAL and shared-memory files are deleted (what they held is in the pre-restore backup), then one `rename` puts the copy in place of `vault.sqlite`, and the scratch files go.

If steps 1–5 fail, the copy is deleted and the vault is unchanged; the app logs the failure and opens the current vault. A crash during step 6 can leave `vault.sqlite` without its last WAL transactions, which the pre-restore backup still holds.

**What a restore still brings back:** everything about the memories themselves, including their sensitivity and categories. A memory whose sensitivity was raised, or that was moved into a denied category, after the backup comes back with its old labels, and agents' access applies to those. The same goes for earlier versions, the Inbox and settings kept in the database, such as `meta('keep_revisions')`.

**Learned facts (v0.10)** come back as the backup holds them, like the memories they were learned from. A memory's evidence is still keyed to its versions, so nothing is re-learned. The restore sets a new `meta('facts_epoch')`, so the facts revision changes even if the backup's counter matches, and the iPhone drops its held answer.

Not carried forward: Remote Access's connected cloud apps live in `remote-connections.json`, which a restore doesn't touch. Each call is checked against the agent's cloud access and removal (`FunesRemoteServer`), which come from the current vault.

### 5.2 Learned facts in exports (v0.10)
`funesvault.export.v1` gains an optional `facts` object, so an export round-trips the learned facts: `entities`, `aliases`, `aliasEvidence`, `facts`, `evidence`, `decisions`, `decisionDependencies`, `manualOverrides`, `runs` and `asked` (what each reading of an exported memory was asked knowing, at its current version: digests and read keys, no names), each row as stored, tombstones included. Each memory also gains an optional `source` (its original one). An export without them (older, or with no learned facts) restores as before.
- **Written** whenever the vault has learned facts, manual entries or model readings (one that found nothing counts), with the memories it exports; evidence and decisions for memories left out of the export (archived ones, when they aren't included) are left out too, and so are names and labels only those memories support, as purge would (what the user made stays, as tombstones where needed).
- **Restored** only into a vault with no learned facts and no manual entries (otherwise the preview says "Learned facts in this file aren't restored: this vault already has its own."). One rule per restore choice:
  - **Restore as active memories:** the `facts` object restores as it is, each memory id mapped to the memory it was restored as, at its new version (its `asked` rows too, so the model doesn't read it again in full and reconciliation can compare it; a memory that didn't come back has none restored). Each memory keeps its own date (`created_at`) and its original source (`original_source`), so the answers survive. This is the identity-preserving restore under which a rejection keyed to a memory holds again (§4).
  - **Restore as suggestions:** inferred rows are dropped (they're learned again once the memories are applied), while manual entries, user evidence, corrections and their tombstones restore with their sensitivity.
  - **A memory that didn't come back** (a duplicate or blocked item the import skipped, or every memory under restore as suggestions) is restored and then purged: its rows restore under a staging id that no memory has, then the same purge that removing a memory runs (§4) removes them. Its evidence and model decisions go, with their dependencies; a correction made from it keeps its exported memory id but loses its quote and mention; what it supported goes, becomes a tombstone or is touched, so decisions resting on it are re-validated. Restoring some of an export's memories therefore leaves the vault as restoring all of them and then purging the rest would, and restoring all of them leaves it as it was. A correction whose memory was purged before the export (not in it, already without its quote) restores as it is and isn't purged again, so the decisions made since stay valid. A model decision depending on a memory that didn't come back is stale, whatever memory the vault has under that id. The restore runs in its own savepoint with foreign keys checked when it ends (the staging evidence names no memory until the purge removes it); a restore that would leave a dangling row fails and leaves nothing behind.
- **Never** in it: the Facts task's settings (user defaults), qualification records and off-switches (`fact_qualification`), or anything a provider holds. The profile's names aren't added: *you* has none.

## 6. iPhone storage

- **App Group container:** `capture-queue.sqlite` (the capture queue), with file protection `completeUntilFirstUserAuthentication`.
- **Keychain:** device signing and HPKE keys, and the pairing record (Mac public keys, ids, addresses).
- **App Group container (v0.4):** `overview.json`, the last `overview.get` answer for each range (counts, dates and agent names; no memory text or titles), with the same file protection, for Home and the widgets ([ADR-0025](decisions/0025-vault-overview-and-iphone-cache.md); [companion protocol §6.1](companion-protocol.md#61-overview-cache-phone-v04)).
- **Keychain (v0.5):** the called name from the last `status.get`, in the pairing record, for Home's title while the Mac is away ([ADR-0026](decisions/0026-about-you-profile.md)). Deleted with the pairing.
- **No** other vault data. Search results and memory details live only in memory while on screen.
- **Demo vault:** a read-only JSON resource in the app bundle.
