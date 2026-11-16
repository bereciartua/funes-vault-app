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
}

enum FactsExport {
    static var tables: [(key: WritableKeyPath<FunesExportFacts, FunesExportFacts.Rows>, table: String, filter: String)] { [
        (\.runs, "facts_run", ""), (\.entities, "entity", "WHERE is_you = 0"), (\.aliases, "entity_alias", ""),
        (\.aliasEvidence, "alias_evidence", ""), (\.facts, "fact", ""), (\.evidence, "fact_evidence", ""),
        (\.decisions, "mention_decision", ""), (\.decisionDependencies, "decision_dependency", ""),
        (\.manualOverrides, "manual_override", ""),
    ] }

    /// Whether the vault has learned facts or manual entries.
    static func hasAny(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM entity WHERE is_you = 0) OR EXISTS (SELECT 1 FROM fact)
              OR EXISTS (SELECT 1 FROM manual_override)
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
            for t in tables {
                out[keyPath: t.key] = try Row.fetchAll(db, sql: "SELECT * FROM \(t.table) \(t.filter) ORDER BY rowid").map { row in
                    Dictionary(uniqueKeysWithValues: row.columnNames.map { ($0, ExportCell(row[$0] as DatabaseValue)) })
                }
            }
            return .rollback
        }
        return out
    }

    /// Restores an export's facts into a vault with none (storage §5.2). `memories` maps each exported memory id to
    /// the memory it was restored as and its version (restore as active memories); nil means the memories became
    /// suggestions, so only manual entries, the user's rows, corrections and their tombstones come back.
    @discardableResult
    static func restore(_ db: Database, _ facts: FunesExportFacts, memories: [String: (id: String, version: Int)]?,
                        now: Date) throws -> Bool {
        guard try !hasAny(db) else { return false }
        func remap(_ row: [String: ExportCell], memoryColumn: String = "memory_id",
                   versionColumn: String? = "memory_version") -> [String: ExportCell]? {
            guard let old = row[memoryColumn]?.string else { return row }
            guard let memories else { return row }
            guard let new = memories[old] else { return nil }
            var r = row
            r[memoryColumn] = .string(new.id)
            if let versionColumn, r[versionColumn] != nil, r[versionColumn] != .null { r[versionColumn] = .int(Int64(new.version)) }
            return r
        }
        /// A correction keeps its ids; it follows its memory if that came back, else it loses its text (as a purge
        /// leaves it), so no quote outlives the memory it came from.
        func correction(_ row: [String: ExportCell]) -> [String: ExportCell] {
            guard let old = row["memory_id"]?.string else { return row }
            var r = row
            if let new = memories?[old] {
                r["memory_id"] = .string(new.id)
            } else {
                if r["mention"] != nil { r["mention"] = .null }
                r["quote"] = .null
            }
            return r
        }
        let asMemories = memories != nil
        // Dependencies follow only the decisions restored: one whose memory was skipped (a duplicate) takes them along.
        var restoredDecisions = Set<String>()
        for t in tables {
            let columns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(t.table))").map { $0["name"] as String })
            for var row in facts[keyPath: t.key] {
                switch t.table {
                case "facts_run":
                    guard asMemories else { continue }
                case "alias_evidence":
                    guard asMemories, let r = remap(row) else { continue }
                    row = r
                case "fact_evidence":
                    if row["source"]?.string == "memory" {
                        guard asMemories, let r = remap(row) else { continue }
                        row = r
                    }
                case "mention_decision":
                    if row["source"]?.string == "model" {
                        guard asMemories, let r = remap(row) else { continue }
                        row = r
                    } else {
                        row = correction(row)
                    }
                case "decision_dependency":
                    guard restoredDecisions.contains(row["decision_id"]?.string ?? "") else { continue }
                    if row["kind"]?.string == "memory", let old = row["ref_id"]?.string {
                        guard let new = memories?[old] else { continue }
                        row["ref_id"] = .string(new.id)
                        row["ref_version"] = .string(String(new.version))
                    }
                case "manual_override":
                    row = correction(row)
                default:
                    break
                }
                let keys = row.keys.filter(columns.contains).sorted()
                guard !keys.isEmpty else { continue }
                try db.execute(sql: "INSERT OR IGNORE INTO \(t.table) (\(keys.joined(separator: ", "))) VALUES (\(databaseQuestionMarks(count: keys.count)))",
                               arguments: StatementArguments(keys.map { row[$0]!.databaseValue }))
                if t.table == "mention_decision", db.changesCount > 0, let id = row["id"]?.string { restoredDecisions.insert(id) }
            }
        }
        try FactStore.collectGarbage(db, now: now)
        try FactStore.bumpRevision(db)
        return true
    }
}
