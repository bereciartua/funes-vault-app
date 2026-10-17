import Foundation
import FunesProtocol
import GRDB

/// Where an import came from (`import_run.source`).
public enum ImportSource: String, Sendable, Codable, CaseIterable {
    case chatgpt, claude, markdown, funes
}

/// One parsed item, before review.
public struct ImportItem: Sendable, Hashable {
    public var title: String
    public var body: String
    /// Matched category keys; empty for "unmatched" (classified on commit).
    public var categoryKeys: [String]
    /// The Markdown heading an unmatched item sat under, for per-item review.
    public var unmatchedHeading: String?
    public var kind: MemoryKind?
    public var sensitivity: Sensitivity?
    public var expiresAt: Date?
    public var createdAt: Date?

    public init(title: String, body: String, categoryKeys: [String] = [], unmatchedHeading: String? = nil,
                kind: MemoryKind? = nil, sensitivity: Sensitivity? = nil, expiresAt: Date? = nil, createdAt: Date? = nil) {
        self.title = title
        self.body = body
        self.categoryKeys = categoryKeys
        self.unmatchedHeading = unmatchedHeading
        self.kind = kind
        self.sensitivity = sensitivity
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }

    /// An item from free text: the first line (up to 80 characters) is the title.
    static func text(_ text: String, categories: [String] = [], heading: String? = nil, createdAt: Date? = nil) -> ImportItem {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
        return ImportItem(title: CaptureProposal.trim(first, to: InputLimits.proposedTitle), body: body,
                          categoryKeys: categories, unmatchedHeading: heading, createdAt: createdAt)
    }
}

public enum ImportError: Error, Sendable, Equatable {
    case unreadable
    case unsupportedFormat
}

/// The import parsers (memory processing §7, FR-X-01..03, FR-X-06). Tolerant: anything they can't
/// use is skipped, not an error, unless nothing in the input is usable.
public enum ImportParser {
    /// A ChatGPT memory export: an array of strings, or of objects with `content`, `memory`, `text`
    /// or `value` (also wrapped in `{"memories": […]}` or similar), with `created_at`/`updated_at`.
    public static func chatGPT(_ data: Data) throws -> [ImportItem] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { throw ImportError.unreadable }
        var entries: [Any] = []
        if let array = json as? [Any] {
            entries = array
        } else if let object = json as? [String: Any] {
            entries = ["memories", "items", "data", "results"].lazy.compactMap { object[$0] as? [Any] }.first ?? []
        }
        let items = entries.compactMap { entry -> ImportItem? in
            if let text = entry as? String { return text.isBlank ? nil : .text(text) }
            guard let o = entry as? [String: Any],
                  let text = ["content", "memory", "text", "value"].lazy.compactMap({ o[$0] as? String }).first, !text.isBlank
            else { return nil }
            return .text(text, createdAt: date(o["created_at"]) ?? date(o["updated_at"]))
        }
        guard !items.isEmpty || entries.isEmpty else { throw ImportError.unsupportedFormat }
        return items
    }

    /// Pasted Claude memories: one item per line or bullet; empty lines and headings dropped.
    public static func claude(_ text: String) -> [ImportItem] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let item = stripBullet(line)
            return item.isBlank ? nil : .text(item)
        }
    }

    /// Markdown: `#`/`##` headings map to categories by name or key (case-insensitive), otherwise
    /// the items under them are unmatched. Bullets and paragraphs become items.
    public static func markdown(_ text: String, categories: [MemoryCategory]) -> [ImportItem] {
        var items: [ImportItem] = []
        var matched: [String] = []
        var heading: String?
        var paragraph: [String] = []
        func flush() {
            let joined = paragraph.joined(separator: " ")
            if !joined.isBlank { items.append(.text(joined, categories: matched, heading: matched.isEmpty ? heading : nil)) }
            paragraph = []
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                flush()
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                heading = title
                let key = title.lowercased()
                matched = categories.filter { $0.name.lowercased() == key || $0.key == key.replacingOccurrences(of: " ", with: "_") }
                    .map(\.key)
            } else if line.isEmpty {
                flush()
            } else if isBullet(line) {
                flush()
                let item = stripBullet(line)
                if !item.isBlank { items.append(.text(item, categories: matched, heading: matched.isEmpty ? heading : nil)) }
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return items
    }

    /// A `funesvault.export.v1` file: its categories and memories.
    public static func funesExport(_ data: Data) throws -> FunesExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let export = try? decoder.decode(FunesExport.self, from: data) else { throw ImportError.unreadable }
        guard export.format == FunesExport.formatID else { throw ImportError.unsupportedFormat }
        return export
    }

    static func isBullet(_ line: String) -> Bool { stripBullet(line) != line }

    static func stripBullet(_ line: String) -> String {
        for marker in ["- [ ] ", "- [x] ", "- ", "* ", "• ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        // Numbered: "1. " or "1) "
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        }
        return line
    }

    static func date(_ value: Any?) -> Date? {
        if let n = value as? Double { return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n) }
        if let s = value as? String {
            let f = ISO8601DateFormatter()
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s)
        }
        return nil
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// `funesvault.export.v1` (FR-X-05): categories and memories, never keys, devices, agents, access
/// or Activity.
public struct FunesExport: Codable, Sendable, Hashable {
    public static let formatID = "funesvault.export.v1"

    public struct Category: Codable, Sendable, Hashable {
        public var key: String
        public var name: String
        public var description: String
        public var defaultSensitivity: Sensitivity
    }

    public struct Memory: Codable, Sendable, Hashable {
        public var id: UUID
        public var title: String
        public var body: String
        public var kind: MemoryKind
        public var categories: [String]
        public var sensitivity: Sensitivity
        public var status: MemoryStatus
        public var expiresAt: Date?
        public var createdAt: Date
        public var updatedAt: Date
    }

    public var format: String
    public var exportedAt: Date
    public var categories: [Category]
    public var memories: [Memory]
}

/// What an import would do, shown before anything is stored (FR-X-04).
public struct ImportPreview: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case ready
        /// The same normalized text is already in the vault, or earlier in this import.
        case duplicate(of: UUID?)
        /// The secret scanner matched; it will never be stored.
        case blocked([SecretPattern])
        /// Over the body limit: split or truncate it first.
        case tooLong
    }
    public struct Entry: Sendable, Hashable {
        public var item: ImportItem
        public var status: Status
    }

    public var source: ImportSource
    public var entries: [Entry]
    /// Categories a Funes export brings that the vault doesn't have yet (created on commit).
    public var newCategories: [FunesExport.Category]

    public var total: Int { entries.count }
    public var duplicates: Int { entries.filter { if case .duplicate = $0.status { true } else { false } }.count }
    public var blocked: Int { entries.filter { if case .blocked = $0.status { true } else { false } }.count }
    public var tooLong: Int { entries.filter { $0.status == .tooLong }.count }

    public enum LongItems: Sendable { case split, truncate }

    /// Resolves over-long items the user's way, then re-checks them.
    public func resolvingLongItems(_ choice: LongItems) -> [ImportItem] {
        entries.flatMap { e -> [ImportItem] in
            guard e.status == .tooLong else { return [e.item] }
            let limit = InputLimits.body.upperBound
            let scalars = Array(e.item.body.unicodeScalars)
            let pieces: [String] = switch choice {
            case .truncate: [CaptureProposal.trim(e.item.body, to: limit)]
            case .split: stride(from: 0, to: scalars.count, by: limit).map {
                String(String.UnicodeScalarView(scalars[$0..<min($0 + limit, scalars.count)]))
            }
            }
            return pieces.enumerated().map { i, piece in
                var item = e.item
                item.body = piece
                if pieces.count > 1 { item.title = CaptureProposal.trim("\(e.item.title) (\(i + 1)/\(pieces.count))", to: 180) }
                return item
            }
        }
    }
}

public struct ImportResult: Sendable, Hashable {
    public var importRunID: UUID
    public var suggestionIDs: [UUID]
    public var memoryIDs: [UUID]
    public var skipped: Int
}

/// Import preview and commit, and export (FR-X-01..06). Imports create suggestions (or, for a
/// Funes export after confirmation, active memories); they never create agents or access.
public final class ImportService: Sendable {
    public let store: VaultStore
    public let activity: any ActivityRecorder

    public init(store: VaultStore, activity: any ActivityRecorder) {
        self.store = store
        self.activity = activity
    }

    public func preview(_ items: [ImportItem], source: ImportSource, newCategories: [FunesExport.Category] = []) async throws -> ImportPreview {
        try await store.writer.read { db in
            let existing = Set(try CategoryStore.all(db).map(\.key))
            var seen: [String: Int] = [:]
            var entries: [ImportPreview.Entry] = []
            for item in items {
                let status: ImportPreview.Status
                let findings = SecretScanner.scan([item.title, item.body])
                let key = MemoryStore.normalized(item.title) + "\u{1F}" + MemoryStore.normalized(item.body)
                if !findings.isEmpty {
                    status = .blocked(findings)
                } else if InputLimits.length(of: item.body) > InputLimits.body.upperBound {
                    status = .tooLong
                } else if let dup = try MemoryStore.exactDuplicates(db, title: item.title, body: item.body).first {
                    status = .duplicate(of: dup)
                } else if seen[key] != nil {
                    status = .duplicate(of: nil)
                } else {
                    status = .ready
                }
                seen[key, default: 0] += 1
                entries.append(.init(item: item, status: status))
            }
            return ImportPreview(source: source, entries: entries, newCategories: newCategories.filter { !existing.contains($0.key) })
        }
    }

    /// A preview of a Funes export: its memories, and the categories to create.
    public func preview(funesExport export: FunesExport) async throws -> ImportPreview {
        let items = export.memories.filter { $0.status != .deleted }.map {
            ImportItem(title: $0.title, body: $0.body, categoryKeys: $0.categories, kind: $0.kind, sensitivity: $0.sensitivity,
                       expiresAt: $0.expiresAt, createdAt: $0.createdAt)
        }
        return try await preview(items, source: .funes, newCategories: export.categories)
    }

    /// Stores the ready items (and duplicates when asked) in one transaction, with an import run.
    /// Blocked and over-long items are never stored. `asMemories` (Funes exports only, after the
    /// user confirms) creates active memories instead of suggestions.
    public func commit(_ preview: ImportPreview, includeDuplicates: Bool = false, asMemories: Bool = false,
                       now: Date) async throws -> ImportResult {
        guard !asMemories || preview.source == .funes else { throw VaultError.invalidInput(field: "as_memories") }
        let runID = UUID()
        let result = try await store.writer.write { db -> ImportResult in
            for c in preview.newCategories where try CategoryStore.fetch(db, key: c.key) == nil && MemoryCategory.isValidKey(c.key) {
                let order = (try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM category") ?? 0) + 1
                try db.execute(sql: """
                    INSERT INTO category (key, name, description, builtin, default_sensitivity, sort_order) VALUES (?, ?, ?, 0, ?, ?)
                    """, arguments: [c.key, c.name, c.description, c.defaultSensitivity.rawValue, order])
            }
            let blocked = preview.entries.filter { if case .blocked = $0.status { true } else { false } }.count
            try db.execute(sql: "INSERT INTO import_run (id, source, created_at, item_count, blocked) VALUES (?, ?, ?, ?, ?)",
                           arguments: [runID.db, preview.source.rawValue, now, preview.total, blocked])
            let categories = try CategoryStore.all(db)
            let known = Set(categories.map(\.key))
            var out = ImportResult(importRunID: runID, suggestionIDs: [], memoryIDs: [], skipped: 0)
            for entry in preview.entries {
                switch entry.status {
                case .ready: break
                case .duplicate where includeDuplicates: break
                default:
                    out.skipped += 1
                    continue
                }
                let item = entry.item
                var keys = item.categoryKeys.filter(known.contains)
                if keys.isEmpty { keys = RulesClassifier.propose(item.title + "\n" + item.body, categories: categories).categoryKeys }
                if asMemories {
                    let m = try MemoryStore.insert(db, MemoryDraft(
                        title: item.title, body: item.body, kind: item.kind ?? .fact, categoryKeys: keys,
                        sensitivity: item.sensitivity, expiresAt: item.expiresAt, source: .importFunes), actor: .importRun(runID), now: now)
                    out.memoryIDs.append(m.id)
                } else {
                    let sensitivity = try item.sensitivity ?? MemoryStore.defaultSensitivity(db, categoryKeys: keys)
                    guard InputLimits.title.contains(InputLimits.length(of: item.title)) else { out.skipped += 1; continue }
                    let id = try SuggestionService.insertSuggestion(
                        db, origin: .import, importRunID: runID,
                        input: SuggestInput(title: item.title, body: item.body, kind: item.kind, expiresAt: item.expiresAt),
                        categories: keys, sensitivity: sensitivity, now: now)
                    out.suggestionIDs.append(id)
                }
            }
            return out
        }
        activity.record(ActivityEvent(time: now, phase: .event, actor: .importRun(runID), via: .app, event: "import",
                                      outcome: "committed", counts: ["suggestions": result.suggestionIDs.count,
                                                                     "memories": result.memoryIDs.count, "skipped": result.skipped]))
        return result
    }

    /// `funesvault.export.v1` JSON of the categories and the active (optionally archived) memories.
    public func export(includeArchived: Bool = false, now: Date) async throws -> Data {
        let export = try await store.writer.read { db -> FunesExport in
            let categories = try CategoryStore.all(db).map {
                FunesExport.Category(key: $0.key, name: $0.name, description: $0.description, defaultSensitivity: $0.defaultSensitivity)
            }
            var memories = try MemoryStore.list(db, filter: MemoryFilter(status: .activeIncludingExpired, sort: .created), now: now)
            if includeArchived { memories += try MemoryStore.list(db, filter: MemoryFilter(status: .archived, sort: .created), now: now) }
            return FunesExport(format: FunesExport.formatID, exportedAt: now, categories: categories, memories: memories.map {
                FunesExport.Memory(id: $0.id, title: $0.title, body: $0.body, kind: $0.kind, categories: $0.categoryKeys,
                                   sensitivity: $0.sensitivity, status: $0.status, expiresAt: $0.expiresAt,
                                   createdAt: $0.createdAt, updatedAt: $0.updatedAt)
            })
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(export)
    }
}
