import Foundation
import GRDB

/// One stored value in an exported row.
public enum ExportCell: Codable, Sendable, Hashable {
    case null
    case int(Int64)
    case double(Double)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        }
    }

    init(_ v: DatabaseValue) {
        switch v.storage {
        case .null, .blob: self = .null
        case .int64(let i): self = .int(i)
        case .double(let d): self = .double(d)
        case .string(let s): self = .string(s)
        }
    }

    var databaseValue: DatabaseValue {
        switch self {
        case .null: return .null
        case .int(let i): return i.databaseValue
        case .double(let d): return d.databaseValue
        case .string(let s): return s.databaseValue
        }
    }

    var string: String? { if case .string(let s) = self { s } else { nil } }
    var int: Int? { if case .int(let i) = self { Int(i) } else { nil } }
}

/// The learned facts in a `funesvault.export.v1` file (storage §5.2): each row as stored, tombstones included.
public struct FunesExportFacts: Codable, Sendable, Hashable {
    public typealias Rows = [[String: ExportCell]]
    public var entities: Rows
    public var aliases: Rows
    public var aliasEvidence: Rows
    public var facts: Rows
    public var evidence: Rows
    public var decisions: Rows
    public var decisionDependencies: Rows
    public var manualOverrides: Rows
    public var runs: Rows
    /// What each model reading of an exported memory was asked knowing (`facts_asked`, at the memory's current version),
    /// so a restored memory isn't read again in full and reconciliation can compare it. Absent in older exports.
    public var asked: Rows? = nil
}

enum FactsExport {
    /// `facts_asked`'s columns: a row restores only whole.
    static let askedColumns: Set<String> = ["memory_id", "memory_version", "call_group", "mention_kind", "mention_key",
                                            "knowledge", "asked_at"]

    static var tables: [(key: WritableKeyPath<FunesExportFacts, FunesExportFacts.Rows>, table: String, filter: String)] { [
        (\.runs, "facts_run", ""), (\.entities, "entity", "WHERE is_you = 0"), (\.aliases, "entity_alias", ""),
        (\.aliasEvidence, "alias_evidence", ""), (\.facts, "fact", ""), (\.evidence, "fact_evidence", ""),
        (\.decisions, "mention_decision", ""), (\.decisionDependencies, "decision_dependency", ""),
        (\.manualOverrides, "manual_override", ""),
    ] }

    /// Whether the vault has learned facts or manual entries, or model readings (one that found nothing still counts).
    static func hasAny(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM entity WHERE is_you = 0) OR EXISTS (SELECT 1 FROM fact)
              OR EXISTS (SELECT 1 FROM manual_override) OR EXISTS (SELECT 1 FROM facts_asked)
            """) ?? false
    }

    /// The facts section for an export of these memories: evidence and decisions of memories left out go, and so do
    /// names and labels only they support, exactly as a purge would (computed in a savepoint that's rolled back).
    static func section(_ db: Database, exporting memoryIDs: Set<String>, now: Date) throws -> FunesExportFacts? {
        guard try hasAny(db) else { return nil }
        var out = FunesExportFacts(entities: [], aliases: [], aliasEvidence: [], facts: [], evidence: [], decisions: [],
                                   decisionDependencies: [], manualOverrides: [], runs: [])
        try db.inSavepoint {
            let others = try String.fetchAll(db, sql: "SELECT id FROM memory").filter { !memoryIDs.contains($0) }
            try FactStore.purge(db, memoryIDs: others, now: now)
            // Only evidence at each memory's current version counts, so only that is exported.
            try db.execute(sql: """
                DELETE FROM fact_evidence WHERE source = 'memory'
                  AND memory_version != (SELECT version FROM memory WHERE memory.id = fact_evidence.memory_id)
                """)
            try db.execute(sql: """
                DELETE FROM alias_evidence WHERE memory_version != (SELECT version FROM memory WHERE memory.id = alias_evidence.memory_id)
                """)
            func rows(_ sql: String) throws -> FunesExportFacts.Rows {
                try Row.fetchAll(db, sql: sql).map { row in
                    Dictionary(uniqueKeysWithValues: row.columnNames.map { ($0, ExportCell(row[$0] as DatabaseValue)) })
                }
            }
            for t in tables {
                out[keyPath: t.key] = try rows("SELECT * FROM \(t.table) \(t.filter) ORDER BY rowid")
            }
            // The purge took the other memories' records; only a memory's current version is compared after a restore.
            out.asked = try rows("""
                SELECT a.* FROM facts_asked a JOIN memory m ON m.id = a.memory_id AND m.version = a.memory_version
                ORDER BY a.rowid
                """)
            return .rollback
        }
        return out
    }

    /// Restores an export's facts into a vault with none (storage §5.2). `memories` maps each exported memory id to
    /// the memory it was restored as and its version (restore as active memories); nil means the memories became
    /// suggestions, so only manual entries, the user's rows, corrections and their tombstones come back. `exported` is
    /// the export's own memory ids (nil: every id the section names).
    ///
    /// A memory the export carries that didn't come back (a skipped duplicate, a blocked one, or every memory when they
    /// became suggestions) is handled as if it came back and was then purged: its rows restore under a staging id that
    /// no memory has, then `FactStore.purge` runs on those ids, exactly as when a memory is removed, so what its
    /// evidence, decisions and corrections supported goes, becomes a tombstone or is re-validated by the purge's own
    /// rules. A correction whose memory was purged before the export restores as it is: purging it again would touch
    /// what it corrects and make valid decisions stale. Staging evidence names no memory, so foreign keys are deferred
    /// inside a savepoint; the explicit check before it's released is the only guard (turning deferral off clears what
    /// SQLite would have checked at commit), and any throw rolls the whole restore back.
    @discardableResult
    static func restore(_ db: Database, _ facts: FunesExportFacts, memories: [String: (id: String, version: Int)]?,
                        exported: Set<String>? = nil, now: Date) throws -> Bool {
        guard try !hasAny(db) else { return false }
        // Ids with rows a purge would still change: evidence, model decisions, corrections that keep their text.
        var live = Set<String>()
        for r in facts.aliasEvidence + facts.evidence { if let m = r["memory_id"]?.string { live.insert(m) } }
        for r in facts.decisions + facts.manualOverrides {
            guard let m = r["memory_id"]?.string else { continue }
            let text = [r["quote"], r["mention"]].contains { $0 != nil && $0 != .null }
            if r["source"]?.string == "model" || text { live.insert(m) }
        }
        func purged(_ old: String) -> Bool { memories?[old] == nil && ((exported?.contains(old) ?? true) || live.contains(old)) }
        var staged: [String: String] = [:]                   // memory id → staging id
        // A memory dependency that names no restored memory is staged too (never purged), so garbage collection sees it
        // pointing at no memory and the decision goes stale, whatever memory the target has under that id.
        func target(_ old: String, dependency: Bool = false) -> (id: String, version: Int?) {
            if let new = memories?[old] { return (new.id, new.version) }
            guard dependency || purged(old) else { return (old, nil) }
            if let s = staged[old] { return (s, nil) }
            let s = UUID().db
            staged[old] = s
            return (s, nil)
        }
        let deferred = try Int.fetchOne(db, sql: "PRAGMA defer_foreign_keys") ?? 0
        defer { try? db.execute(sql: "PRAGMA defer_foreign_keys = \(deferred)") }
        try db.inSavepoint {
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            for t in tables {
                // Runs describe how memories were read: they don't come back with suggestions.
                if t.table == "facts_run", memories == nil { continue }
                let columns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(t.table))").map { $0["name"] as String })
                for var row in facts[keyPath: t.key] {
                    if t.table == "decision_dependency" {
                        if row["kind"]?.string == "memory", let old = row["ref_id"]?.string {
                            let m = target(old, dependency: true)
                            row["ref_id"] = .string(m.id)
                            if let v = m.version { row["ref_version"] = .string(String(v)) }
                        }
                    } else if let old = row["memory_id"]?.string {
                        let m = target(old)
                        row["memory_id"] = .string(m.id)
                        if let v = m.version, let c = row["memory_version"], c != .null { row["memory_version"] = .int(Int64(v)) }
                    }
                    let keys = row.keys.filter(columns.contains).sorted()
                    guard !keys.isEmpty else { continue }
                    try db.execute(sql: "INSERT OR IGNORE INTO \(t.table) (\(keys.joined(separator: ", "))) VALUES (\(databaseQuestionMarks(count: keys.count)))",
                                   arguments: StatementArguments(keys.map { row[$0]!.databaseValue }))
                }
            }
            // What each reading was asked knowing, for the memories that came back as active memories, at their new
            // version. One that didn't come back has no reading to compare; restored suggestions are read when applied.
            if let memories {
                for var row in facts.asked ?? [] {
                    guard let old = row["memory_id"]?.string, let new = memories[old] else { continue }
                    row["memory_id"] = .string(new.id)
                    row["memory_version"] = .int(Int64(new.version))
                    let keys = row.keys.filter(Self.askedColumns.contains).sorted()
                    guard Set(keys) == Self.askedColumns else { continue }
                    try db.execute(sql: "INSERT OR IGNORE INTO facts_asked (\(keys.joined(separator: ", "))) VALUES (\(databaseQuestionMarks(count: keys.count)))",
                                   arguments: StatementArguments(keys.map { row[$0]!.databaseValue }))
                }
            }
            let skipped = staged.filter { purged($0.key) }.map(\.value).sorted()
            if skipped.isEmpty {
                try FactStore.collectGarbage(db, now: now)
            } else {
                try FactStore.purge(db, memoryIDs: skipped, now: now)
            }
            // What the purge kept (corrections, without their text; dependencies of stale decisions) carries its
            // exported id again.
            let exportedID = Dictionary(uniqueKeysWithValues: staged.map { ($0.value, $0.key) })
            for (table, column, filter) in [("mention_decision", "memory_id", ""), ("manual_override", "memory_id", ""),
                                            ("decision_dependency", "ref_id", "AND kind = 'memory'")] {
                for s in try String.fetchAll(db, sql: "SELECT DISTINCT \(column) FROM \(table) WHERE \(column) IS NOT NULL \(filter)") {
                    guard let old = exportedID[s] else { continue }
                    try db.execute(sql: "UPDATE \(table) SET \(column) = ? WHERE \(column) = ? \(filter)", arguments: [old, s])
                }
            }
            // A decision's record whose decision didn't come back, or that the purge took, goes too.
            try db.execute(sql: "DELETE FROM facts_asked WHERE mention_kind = 'decision' AND mention_key NOT IN (SELECT id FROM mention_decision)")
            for t in tables.map(\.table) + ["facts_asked"] where try Row.fetchOne(db, sql: "PRAGMA foreign_key_check(\(t))") != nil {
                throw DatabaseError(resultCode: .SQLITE_CONSTRAINT_FOREIGNKEY, message: "dangling \(t) row after a learned facts restore")
            }
            try FactStore.bumpRevision(db)
            return .commit
        }
        return true
    }
}
