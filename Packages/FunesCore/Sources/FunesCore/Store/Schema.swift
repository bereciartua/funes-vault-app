import Foundation
import GRDB
import FunesProtocol

/// The vault schema (spec/architecture/storage.md#2-schema-v1). Forward-only, named migrations.
enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial") { db in
            try db.execute(sql: v1)
            for c in MemoryCategory.builtins {
                try db.execute(
                    sql: """
                        INSERT INTO category (key, name, description, builtin, default_sensitivity, sort_order)
                        VALUES (?, ?, ?, 1, ?, ?)
                        """,
                    arguments: [c.key, c.name, c.description, c.defaultSensitivity.rawValue, c.sortOrder])
            }
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('vault_id', ?)", arguments: [UUID().db])
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('active_embedding_model', ?)",
                           arguments: [EmbeddingModelInfo.bundled.id])
        }
        // Remote Access (ADR-0018, storage §2): per-agent cloud access and its remote token.
        migrator.registerMigration("v2_remote_access") { db in
            try db.execute(sql: v2)
        }
        // Approvals from the iPhone (ADR-0019, task 5.6): per device, on by default, and the
        // doorbell's tag while they're on.
        migrator.registerMigration("v3_device_approvals") { db in
            try db.execute(sql: v3)
        }
        // Memory processing (v0.3, Phase 6.1; ADR-0020, ADR-0021, storage §3): trust and the
        // tidy-up's reconciled version, multi-target and grouped suggestions, the processing
        // queue, the undo log and the tidy-up's runs and dismissals.
        migrator.registerMigration("v4_memory_processing") { db in
            try db.execute(sql: v4)
        }
        // The vault overview (v0.4, Phase 7.2; ADR-0025, storage §3): its time ranges, which took
        // more than 50 ms on a 10,000-memory vault without them.
        migrator.registerMigration("v5_overview_indexes") { db in
            try db.execute(sql: v5)
        }
        // About you (v0.5, Phase 8; ADR-0026, storage §3): the profile, the fields each agent's
        // answers carry (its name, for every agent not removed), and the fields each request sent.
        migrator.registerMigration("v6_profile") { db in
            try db.execute(sql: v6)
        }
        // Earlier versions (v0.5; ADR-0027, storage §3): the state each change replaced, for
        // History and Activity. Nothing to backfill.
        migrator.registerMigration("v7_memory_revisions") { db in
            try db.execute(sql: v7)
        }
        // Tidy Up on one memory (v0.5, memory processing §9.7): which runs were the whole vault's,
        // so one memory's run doesn't stand in for the day's.
        migrator.registerMigration("v8_tidy_up_scope") { db in
            try db.execute(sql: v8)
        }
        // Facts about you (v0.10, Phase 13a.1; ADR-0032, storage §3): learned entities, facts, their evidence,
        // decisions, corrections, qualification off-switches and runs; `facts` jobs per memory version and call
        // group. Nothing to backfill: the tables stay empty, apart from *you*, until the first backfill.
        migrator.registerMigration("v9_facts") { db in
            try db.execute(sql: v9)
            let now = Date()
            try db.execute(sql: "INSERT INTO entity (id, kind, is_you, created_at, updated_at) VALUES (?, 'person', 1, ?, ?)",
                           arguments: [UUID().db, now, now])
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('facts_epoch', ?)", arguments: [UUID().db])
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('facts_revision', '0')")
        }
        // Which call of a memory gave each alias (Phase 13a.2, storage §2): a re-read of one call group replaces only
        // that group's alias evidence, names code found without a model (`source` = code) never reach a roster, and
        // `read_at` says when the reading was made and `first_read_at` when this memory version first gave the alias (a
        // one-word name read before a namesake was known by it reads as ambiguous); `entity_alias.confirmed_at` dates a
        // confirmed or typed alias the same way.
        // The key gains the call group, so the table is rebuilt; it holds no rows before the first backfill.
        migrator.registerMigration("v10_alias_provenance") { db in
            try db.execute(sql: v10)
        }
        return migrator
    }

    static let v10 = """
        CREATE TABLE alias_evidence_v10 (
          alias_id       TEXT NOT NULL REFERENCES entity_alias(id) ON DELETE CASCADE,
          memory_id      TEXT NOT NULL REFERENCES memory(id) ON DELETE CASCADE,
          memory_version INTEGER NOT NULL,
          span_start     INTEGER NOT NULL, span_end INTEGER NOT NULL,
          quote          TEXT NOT NULL,
          sensitivity    INTEGER NOT NULL,
          trust          TEXT NOT NULL CHECK (trust IN ('trusted','untrusted')),
          run_id         TEXT REFERENCES facts_run(id) ON DELETE SET NULL,
          call_group     TEXT NOT NULL DEFAULT '',
          source         TEXT NOT NULL DEFAULT 'model' CHECK (source IN ('model','code')),
          read_at        TEXT,
          first_read_at  TEXT,
          PRIMARY KEY (alias_id, memory_id, memory_version, span_start, call_group)
        );
        INSERT INTO alias_evidence_v10 (alias_id, memory_id, memory_version, span_start, span_end, quote, sensitivity, trust, run_id)
          SELECT alias_id, memory_id, memory_version, span_start, span_end, quote, sensitivity, trust, run_id FROM alias_evidence;
        DROP TABLE alias_evidence;
        ALTER TABLE alias_evidence_v10 RENAME TO alias_evidence;
        CREATE INDEX alias_evidence_memory ON alias_evidence(memory_id);
        ALTER TABLE entity_alias ADD COLUMN confirmed_at TEXT;
        """

    /// Learned facts (storage §2, v9_facts). Owner side only: agent retrieval never reads these tables. No start or
    /// end dates are stored: episodes are derived from `fact_evidence`.
    static let v9 = """
        ALTER TABLE memory ADD COLUMN original_source TEXT;
        CREATE TABLE processing_job_v9 (
          id             TEXT PRIMARY KEY,
          subject        TEXT NOT NULL,
          kind           TEXT NOT NULL CHECK (kind IN ('new_memory','tidy_up','facts')),
          state          TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','running','done','failed')),
          attempts       INTEGER NOT NULL DEFAULT 0,
          engine         TEXT,
          not_before     TEXT,
          error          TEXT,
          created_at     TEXT NOT NULL,
          updated_at     TEXT NOT NULL,
          memory_version INTEGER,
          call_group     TEXT
        );
        INSERT INTO processing_job_v9 (id, subject, kind, state, attempts, engine, not_before, error, created_at, updated_at)
          SELECT id, subject, kind, state, attempts, engine, not_before, error, created_at, updated_at FROM processing_job;
        DROP TABLE processing_job;
        ALTER TABLE processing_job_v9 RENAME TO processing_job;
        CREATE UNIQUE INDEX processing_job_subject ON processing_job(subject, kind, COALESCE(call_group, ''));
        CREATE INDEX processing_job_queue ON processing_job(state, created_at);

        CREATE TABLE facts_run (
          id               TEXT PRIMARY KEY,
          kind             TEXT NOT NULL CHECK (kind IN ('backfill','incremental','reread','reconciliation')),
          call_group       TEXT NOT NULL,
          registry_version TEXT NOT NULL,
          prompt_version   TEXT NOT NULL,
          engine           TEXT NOT NULL,
          cap_exempt       INTEGER NOT NULL DEFAULT 0,
          resume_after     INTEGER,
          counts           TEXT NOT NULL DEFAULT '{}',
          started_at       TEXT NOT NULL,
          finished_at      TEXT,
          error            TEXT
        );

        CREATE TABLE entity (
          id              TEXT PRIMARY KEY,
          kind            TEXT NOT NULL CHECK (kind IN ('person','organization','place','thing')),
          is_you          INTEGER NOT NULL DEFAULT 0,
          name            TEXT,
          group_predicate TEXT, group_label TEXT, group_count INTEGER,
          deceased        INTEGER NOT NULL DEFAULT 0,
          hidden          INTEGER NOT NULL DEFAULT 0,
          manual          INTEGER NOT NULL DEFAULT 0,
          tombstone       INTEGER NOT NULL DEFAULT 0,
          created_at      TEXT NOT NULL,
          updated_at      TEXT NOT NULL
        );
        CREATE UNIQUE INDEX entity_you ON entity(is_you) WHERE is_you = 1;

        CREATE TABLE entity_alias (
          id          TEXT PRIMARY KEY,
          entity_id   TEXT NOT NULL REFERENCES entity(id) ON DELETE CASCADE,
          alias       TEXT,
          normalized  TEXT NOT NULL,
          manual      INTEGER NOT NULL DEFAULT 0,
          confirmed   INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX entity_alias_normalized ON entity_alias(normalized);
        CREATE INDEX entity_alias_entity ON entity_alias(entity_id);

        CREATE TABLE alias_evidence (
          alias_id       TEXT NOT NULL REFERENCES entity_alias(id) ON DELETE CASCADE,
          memory_id      TEXT NOT NULL REFERENCES memory(id) ON DELETE CASCADE,
          memory_version INTEGER NOT NULL,
          span_start     INTEGER NOT NULL, span_end INTEGER NOT NULL,
          quote          TEXT NOT NULL,
          sensitivity    INTEGER NOT NULL,
          trust          TEXT NOT NULL CHECK (trust IN ('trusted','untrusted')),
          run_id         TEXT REFERENCES facts_run(id) ON DELETE SET NULL,
          PRIMARY KEY (alias_id, memory_id, memory_version, span_start)
        );
        CREATE INDEX alias_evidence_memory ON alias_evidence(memory_id);

        CREATE TABLE fact (
          id          TEXT PRIMARY KEY,
          predicate   TEXT NOT NULL,
          entity_id   TEXT NOT NULL REFERENCES entity(id) ON DELETE RESTRICT,
          manual      INTEGER NOT NULL DEFAULT 0,
          tombstone   INTEGER NOT NULL DEFAULT 0,
          created_at  TEXT NOT NULL,
          updated_at  TEXT NOT NULL,
          UNIQUE (predicate, entity_id)
        );
        CREATE INDEX fact_entity ON fact(entity_id);

        CREATE TABLE fact_evidence (
          id             TEXT PRIMARY KEY,
          target_kind    TEXT NOT NULL CHECK (target_kind IN ('fact','qualifier','order')),
          fact_id        TEXT NOT NULL REFERENCES fact(id) ON DELETE CASCADE,
          qualifier      TEXT,
          other_fact_id  TEXT REFERENCES fact(id) ON DELETE CASCADE,
          direction      TEXT CHECK (direction IN ('preceded_by','followed_by')),
          episode_selector       TEXT,
          other_episode_selector TEXT,
          source         TEXT NOT NULL CHECK (source IN ('memory','user')),
          memory_id      TEXT REFERENCES memory(id) ON DELETE CASCADE,
          memory_version INTEGER,
          span_start     INTEGER, span_end INTEGER,
          quote          TEXT,
          asserted       TEXT NOT NULL DEFAULT '{}',
          states         INTEGER NOT NULL,
          polarity       TEXT NOT NULL CHECK (polarity IN ('affirmed','denied')),
          sensitivity    INTEGER NOT NULL,
          trust          TEXT NOT NULL CHECK (trust IN ('trusted','untrusted')),
          call_group     TEXT,
          run_id         TEXT REFERENCES facts_run(id) ON DELETE SET NULL,
          CHECK ((source = 'memory') = (memory_id IS NOT NULL AND memory_version IS NOT NULL AND quote IS NOT NULL))
        );
        CREATE INDEX fact_evidence_fact ON fact_evidence(fact_id, target_kind);
        CREATE INDEX fact_evidence_memory ON fact_evidence(memory_id, memory_version);
        CREATE INDEX fact_evidence_other ON fact_evidence(other_fact_id) WHERE other_fact_id IS NOT NULL;

        CREATE TABLE mention_decision (
          id             TEXT PRIMARY KEY,
          memory_id      TEXT NOT NULL,
          memory_version INTEGER,
          mention        TEXT,
          quote          TEXT,
          span_start     INTEGER, span_end INTEGER,
          outcome        TEXT NOT NULL CHECK (outcome IN ('entity','group','someone_else','unknown','rejected')),
          entity_id      TEXT,
          basis          TEXT NOT NULL,
          source         TEXT NOT NULL CHECK (source IN ('model','user')),
          call_group     TEXT,
          run_id         TEXT REFERENCES facts_run(id) ON DELETE SET NULL,
          created_at     TEXT NOT NULL,
          invalidated_at TEXT
        );
        CREATE INDEX mention_decision_memory ON mention_decision(memory_id);

        CREATE TABLE decision_dependency (
          decision_id TEXT NOT NULL REFERENCES mention_decision(id) ON DELETE CASCADE,
          kind        TEXT NOT NULL CHECK (kind IN ('memory','fact','entity')),
          ref_id      TEXT NOT NULL,
          ref_version TEXT NOT NULL,
          PRIMARY KEY (decision_id, kind, ref_id)
        );
        CREATE INDEX decision_dependency_ref ON decision_dependency(kind, ref_id);

        CREATE TABLE manual_override (
          id               TEXT PRIMARY KEY,
          target_kind      TEXT NOT NULL CHECK (target_kind IN ('entity','alias','fact','qualifier','date','status','order')),
          target_id        TEXT NOT NULL,
          field            TEXT NOT NULL,
          value            TEXT,
          episode_selector TEXT,
          sensitivity      INTEGER NOT NULL,
          memory_id        TEXT,
          quote            TEXT,
          created_at       TEXT NOT NULL,
          updated_at       TEXT NOT NULL
        );
        CREATE INDEX manual_override_target ON manual_override(target_kind, target_id);

        CREATE TABLE fact_qualification (
          predicate        TEXT NOT NULL,
          use              TEXT NOT NULL CHECK (use IN ('recorded','linked','timeline','attributes','bridges')),
          basis            TEXT NOT NULL DEFAULT '',
          model            TEXT NOT NULL,
          prompt_version   TEXT NOT NULL,
          registry_version TEXT NOT NULL,
          adapter          TEXT NOT NULL,
          batching         TEXT NOT NULL,
          gate             TEXT NOT NULL,
          passed           INTEGER NOT NULL,
          recorded_at      TEXT NOT NULL,
          PRIMARY KEY (predicate, use, basis, model, prompt_version, registry_version, adapter, batching)
        );
        """

    /// `all` for the daily run and Tidy Up Now, `memory` for Tidy Up on one memory.
    static let v8 = """
        ALTER TABLE tidy_up_run ADD COLUMN scope TEXT NOT NULL DEFAULT 'all' CHECK (scope IN ('all', 'memory'));
        """

    /// One row per version a change replaced; purged with its memory.
    static let v7 = """
        CREATE TABLE memory_revision (
          memory_id      TEXT NOT NULL REFERENCES memory(id) ON DELETE CASCADE,
          version        INTEGER NOT NULL,
          title          TEXT NOT NULL,
          body           TEXT NOT NULL,
          kind           TEXT NOT NULL,
          category_keys  TEXT NOT NULL DEFAULT '[]',
          sensitivity    INTEGER NOT NULL,
          status         TEXT NOT NULL,
          expires_at     TEXT,
          replaced_at    TEXT NOT NULL,
          replaced_by    TEXT NOT NULL,
          PRIMARY KEY (memory_id, version)
        );
        CREATE INDEX memory_revision_replaced ON memory_revision(replaced_at);
        """

    /// No profile row until the user first saves About You.
    static let v6 = """
        CREATE TABLE profile (
          id              INTEGER PRIMARY KEY CHECK (id = 1),
          given_name      TEXT,
          family_name     TEXT,
          preferred_name  TEXT,
          pronouns        TEXT,
          languages       TEXT NOT NULL DEFAULT '[]',
          location        TEXT,
          time_zone       TEXT NOT NULL DEFAULT 'automatic',
          occupation      TEXT,
          updated_at      TEXT
        );
        CREATE TABLE access_profile_field (
          agent_id TEXT NOT NULL REFERENCES agent(id) ON DELETE CASCADE,
          field    TEXT NOT NULL CHECK (field IN ('name','pronouns','languages','location','time_zone','occupation')),
          PRIMARY KEY (agent_id, field)
        );
        INSERT INTO access_profile_field (agent_id, field) SELECT id, 'name' FROM agent WHERE removed_at IS NULL;
        ALTER TABLE disclosure ADD COLUMN profile_fields_sent TEXT NOT NULL DEFAULT '[]';
        """

    /// The overview's reads (ADR-0025): new memories by `created_at`, deliveries by
    /// `delivered_at` (only delivered requests have one), requests by `created_at`, and the
    /// active memories' shape. Each carries the columns its query groups by, so the scans don't
    /// visit the rows, which hold memory text and candidate snapshots.
    static let v5 = """
        CREATE INDEX memory_created ON memory(created_at, source, source_device_id);
        CREATE INDEX memory_status_shape ON memory(status, sensitivity, kind, id);
        CREATE INDEX disclosure_delivered ON disclosure(delivered_at, agent_id) WHERE delivered_at IS NOT NULL;
        CREATE INDEX disclosure_created ON disclosure(created_at, agent_id, status, reason);
        CREATE INDEX disclosure_item_shape ON disclosure_item(disclosure_id, sensitivity, category_key);
        """

    /// `suggestion.group_id` and `suggestion_target.memory_id` carry no foreign key: a piece
    /// outlives its group's source text, and a target that was purged must read as changed, not
    /// vanish from a merge.
    static let v4 = """
        ALTER TABLE memory ADD COLUMN trust TEXT NOT NULL DEFAULT 'trusted' CHECK (trust IN ('trusted','untrusted'));
        UPDATE memory SET trust = 'untrusted' WHERE source = 'agent_write';
        ALTER TABLE memory ADD COLUMN reconciled_version INTEGER;

        ALTER TABLE suggestion ADD COLUMN target_memory_version INTEGER;
        ALTER TABLE suggestion ADD COLUMN group_id TEXT;
        ALTER TABLE suggestion ADD COLUMN intent TEXT CHECK (intent IN ('assertion','remember','correction','retraction'));
        ALTER TABLE suggestion ADD COLUMN outside_scope INTEGER NOT NULL DEFAULT 0;
        CREATE INDEX suggestion_by_group ON suggestion(group_id) WHERE group_id IS NOT NULL;

        CREATE TABLE suggestion_target (
          suggestion_id  TEXT NOT NULL REFERENCES suggestion(id) ON DELETE CASCADE,
          memory_id      TEXT NOT NULL,
          memory_version INTEGER NOT NULL,
          role           TEXT NOT NULL CHECK (role IN ('target','source','survivor')),
          position       INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (suggestion_id, memory_id)
        );
        CREATE INDEX suggestion_target_memory ON suggestion_target(memory_id);

        CREATE TABLE suggestion_group (
          id          TEXT PRIMARY KEY,
          origin      TEXT NOT NULL,
          agent_id    TEXT REFERENCES agent(id),
          source_text TEXT,
          engine      TEXT,
          created_at  TEXT NOT NULL
        );

        CREATE TABLE processing_job (
          id         TEXT PRIMARY KEY,
          subject    TEXT NOT NULL,
          kind       TEXT NOT NULL CHECK (kind IN ('new_memory','tidy_up')),
          state      TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','running','done','failed')),
          attempts   INTEGER NOT NULL DEFAULT 0,
          engine     TEXT,
          not_before TEXT,
          error      TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE UNIQUE INDEX processing_job_subject ON processing_job(subject, kind);
        CREATE INDEX processing_job_queue ON processing_job(state, created_at);

        CREATE TABLE undo_entry (
          id            TEXT PRIMARY KEY,
          created_at    TEXT NOT NULL,
          run_id        TEXT,
          suggestion_id TEXT,
          action        TEXT NOT NULL,
          memory_ids    TEXT NOT NULL DEFAULT '[]',
          before_state  TEXT NOT NULL,
          undone_at     TEXT,
          expires_at    TEXT NOT NULL
        );
        CREATE INDEX undo_entry_created ON undo_entry(created_at DESC);

        CREATE TABLE tidy_up_run (
          id          TEXT PRIMARY KEY,
          started_at  TEXT NOT NULL,
          finished_at TEXT,
          engine      TEXT,
          inspected   INTEGER NOT NULL DEFAULT 0,
          clusters    INTEGER NOT NULL DEFAULT 0,
          suggestions INTEGER NOT NULL DEFAULT 0,
          applied     INTEGER NOT NULL DEFAULT 0,
          partial     INTEGER NOT NULL DEFAULT 0,
          error       TEXT
        );

        CREATE TABLE tidy_up_dismissal (
          memory_ids   TEXT NOT NULL,
          content_hash TEXT NOT NULL,
          dismissed_at TEXT NOT NULL,
          PRIMARY KEY (memory_ids, content_hash)
        );

        ALTER TABLE provenance ADD COLUMN related_memory_id TEXT;
        ALTER TABLE provenance ADD COLUMN engine TEXT;
        """

    static let v3 = """
        ALTER TABLE device ADD COLUMN approvals_enabled INTEGER NOT NULL DEFAULT 1;
        ALTER TABLE device ADD COLUMN doorbell_tag TEXT;
        """

    static let v2 = """
        ALTER TABLE agent ADD COLUMN cloud_access INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE agent ADD COLUMN remote_key_digest BLOB;
        ALTER TABLE agent ADD COLUMN remote_key_issued_at TEXT;
        CREATE UNIQUE INDEX agent_remote_key_digest ON agent(remote_key_digest) WHERE remote_key_digest IS NOT NULL;
        """

    /// `memory.seq` is an INTEGER PRIMARY KEY so the FTS external content keeps stable rowids:
    /// a table whose primary key isn't an integer can get new rowids on VACUUM.
    static let v1 = """
        CREATE TABLE category (
          key                 TEXT PRIMARY KEY,
          name                TEXT NOT NULL,
          description         TEXT NOT NULL DEFAULT '',
          builtin             INTEGER NOT NULL DEFAULT 0,
          default_sensitivity INTEGER NOT NULL DEFAULT 1 CHECK (default_sensitivity BETWEEN 0 AND 5),
          sort_order          INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE agent (
          id                 TEXT PRIMARY KEY,
          name               TEXT NOT NULL,
          agent_kind         TEXT NOT NULL,
          key_digest         BLOB,
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
          max_sensitivity    INTEGER NOT NULL DEFAULT 1 CHECK (max_sensitivity BETWEEN 0 AND 5),
          ask_before_sharing INTEGER NOT NULL DEFAULT 1,
          ask_before_saving  INTEGER NOT NULL DEFAULT 1,
          expires_at         TEXT
        );

        CREATE TABLE access_category (
          agent_id     TEXT NOT NULL REFERENCES agent(id) ON DELETE CASCADE,
          category_key TEXT NOT NULL REFERENCES category(key) ON UPDATE CASCADE ON DELETE CASCADE,
          mode         TEXT NOT NULL CHECK (mode IN ('allow','deny')),
          PRIMARY KEY (agent_id, category_key, mode)
        );

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

        CREATE TABLE memory (
          seq               INTEGER PRIMARY KEY,
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

        CREATE VIRTUAL TABLE memory_fts USING fts5(
          title, body, content='memory', content_rowid='seq',
          tokenize='porter unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER memory_ai AFTER INSERT ON memory BEGIN
          INSERT INTO memory_fts(rowid, title, body) VALUES (new.seq, new.title, new.body);
        END;
        CREATE TRIGGER memory_ad AFTER DELETE ON memory BEGIN
          INSERT INTO memory_fts(memory_fts, rowid, title, body) VALUES ('delete', old.seq, old.title, old.body);
        END;
        CREATE TRIGGER memory_au AFTER UPDATE OF title, body ON memory BEGIN
          INSERT INTO memory_fts(memory_fts, rowid, title, body) VALUES ('delete', old.seq, old.title, old.body);
          INSERT INTO memory_fts(rowid, title, body) VALUES (new.seq, new.title, new.body);
        END;

        CREATE TABLE embedding (
          memory_id    TEXT NOT NULL REFERENCES memory(id) ON DELETE CASCADE,
          model_id     TEXT NOT NULL,
          dims         INTEGER NOT NULL,
          vector       BLOB NOT NULL,
          content_hash TEXT NOT NULL,
          PRIMARY KEY (memory_id, model_id)
        );

        CREATE TABLE provenance (
          id             INTEGER PRIMARY KEY AUTOINCREMENT,
          memory_id      TEXT NOT NULL REFERENCES memory(id) ON DELETE CASCADE,
          at             TEXT NOT NULL,
          event          TEXT NOT NULL,
          actor          TEXT NOT NULL,
          fields_changed TEXT
        );
        CREATE INDEX provenance_memory ON provenance(memory_id, at DESC);

        CREATE TABLE disclosure (
          id                   TEXT PRIMARY KEY,
          agent_id             TEXT NOT NULL REFERENCES agent(id),
          agent_revision       INTEGER NOT NULL,
          task_hash            TEXT NOT NULL,
          task_length          INTEGER NOT NULL,
          purpose              TEXT,
          retention            TEXT NOT NULL,
          processors           TEXT NOT NULL DEFAULT '[]',
          max_tokens           INTEGER NOT NULL,
          requested_categories TEXT NOT NULL DEFAULT '[]',
          status               TEXT NOT NULL,
          reason               TEXT,
          candidate_snapshot   TEXT,
          snapshot_revision    TEXT,
          approved_memory_ids  TEXT,
          approval_expires_at  TEXT,
          withheld             TEXT NOT NULL DEFAULT '{}',
          created_at           TEXT NOT NULL,
          decided_at           TEXT,
          delivered_at         TEXT
        );
        CREATE INDEX disclosure_agent_status ON disclosure(agent_id, status);
        CREATE INDEX disclosure_pending ON disclosure(status, created_at) WHERE status IN ('needs_approval','approved');

        CREATE TABLE disclosure_item (
          disclosure_id    TEXT NOT NULL REFERENCES disclosure(id) ON DELETE CASCADE,
          memory_id        TEXT NOT NULL,
          memory_version   INTEGER NOT NULL,
          category_key     TEXT NOT NULL,
          sensitivity      INTEGER NOT NULL,
          estimated_tokens INTEGER NOT NULL,
          clipped          INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (disclosure_id, memory_id)
        );
        CREATE INDEX disclosure_item_memory ON disclosure_item(memory_id);

        CREATE TABLE import_run (
          id          TEXT PRIMARY KEY,
          source      TEXT NOT NULL,
          created_at  TEXT NOT NULL,
          item_count  INTEGER NOT NULL,
          blocked     INTEGER NOT NULL DEFAULT 0
        );

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
          caller_metadata  TEXT,
          classification   TEXT,
          status           TEXT NOT NULL DEFAULT 'pending',
          created_at       TEXT NOT NULL,
          decided_at       TEXT,
          expires_after    TEXT NOT NULL,
          result_memory_id TEXT REFERENCES memory(id) ON DELETE SET NULL
        );
        CREATE INDEX suggestion_pending ON suggestion(status, created_at DESC);

        CREATE TABLE capture_receipt (
          capture_id    TEXT PRIMARY KEY,
          device_id     TEXT NOT NULL REFERENCES device(id),
          received_at   TEXT NOT NULL,
          suggestion_id TEXT NOT NULL REFERENCES suggestion(id)
        );

        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """
}
