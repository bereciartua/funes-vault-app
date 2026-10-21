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
        return migrator
    }

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
