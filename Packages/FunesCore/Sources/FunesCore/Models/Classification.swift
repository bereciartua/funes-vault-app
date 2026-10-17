import Foundation
import FunesProtocol

/// Proposed fields for a capture or suggestion (memory processing §5). Review-only: a proposal
/// is never applied without the user.
public struct CaptureProposal: Sendable, Hashable, Codable {
    public var title: String
    public var kind: MemoryKind
    public var categoryKeys: [String]
    public var sensitivity: Sensitivity
    public var timeLimited: Bool

    public init(title: String, kind: MemoryKind, categoryKeys: [String], sensitivity: Sensitivity, timeLimited: Bool) {
        self.title = title
        self.kind = kind
        self.categoryKeys = categoryKeys
        self.sensitivity = sensitivity
        self.timeLimited = timeLimited
    }

    /// Makes any engine's output safe to show (memory processing §5, model providers §3): unknown
    /// categories dropped (none left: `personal_preferences`), at most 3, sensitivity raised to the
    /// categories' default, title trimmed to 80 characters and never empty.
    public func validated(categories: [MemoryCategory], fallbackTitle: String) -> CaptureProposal {
        let known = Dictionary(uniqueKeysWithValues: categories.map { ($0.key, $0) })
        var seen = Set<String>()
        var keys = categoryKeys.filter { known[$0] != nil && seen.insert($0).inserted }
        if keys.isEmpty { keys = ["personal_preferences"] }
        keys = Array(keys.prefix(3))
        let floor = keys.compactMap { known[$0]?.defaultSensitivity }.max() ?? .low
        var title = Self.trim(title.trimmingCharacters(in: .whitespacesAndNewlines), to: InputLimits.proposedTitle)
        if title.isEmpty { title = Self.trim(fallbackTitle, to: InputLimits.proposedTitle) }
        if title.isEmpty { title = "Note" }
        return CaptureProposal(title: title, kind: kind, categoryKeys: keys, sensitivity: max(sensitivity, floor),
                               timeLimited: timeLimited)
    }

    /// The longest prefix of whole characters within `limit` Unicode scalars.
    static func trim(_ text: String, to limit: Int) -> String {
        var out = ""
        var used = 0
        for c in text {
            let n = c.unicodeScalars.count
            if used + n > limit { break }
            out.append(c)
            used += n
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

/// What a suggestion's `classification` column records: the proposal, the engine, and whether the
/// cloud pre-screen kept the text on the Mac.
public struct ClassificationRecord: Sendable, Hashable, Codable {
    public var engine: String
    public var proposal: CaptureProposal
    public var keptOnDevice: Bool
}

/// The always-available fallback (memory processing §5): title from the first line, kind `fact`,
/// categories by keyword lists, sensitivity from the category default. Also the on-device
/// sensitivity pre-screen before any cloud classification (model providers §5).
public enum RulesClassifier {
    public static let engine = "rules"

    static let keywords: [String: [String]] = [
        "health": ["doctor", "medication", "medicine", "allergy", "allergic", "prescription", "hospital", "symptom",
                   "diagnosis", "therapy", "therapist", "dentist", "surgery", "vaccine", "blood", "pharmacy", "migraine",
                   "asthma", "diabetes", "epipen", "mg"],
        "finance": ["bank", "salary", "rent", "mortgage", "invoice", "tax", "taxes", "budget", "payment", "loan", "credit",
                    "debt", "invest", "investment", "pension", "savings", "insurance", "expense", "expenses", "paid"],
        "legal": ["contract", "lawyer", "attorney", "court", "lease", "lawsuit", "agreement", "notary", "visa", "custody",
                  "will", "testament", "nda", "legal"],
        "software_development": ["code", "repo", "repository", "git", "commit", "swift", "python", "typescript", "javascript",
                                 "api", "deploy", "bug", "build", "compiler", "xcode", "pnpm", "npm", "test", "tests",
                                 "refactor", "pull", "branch"],
        "communication_style": ["tone", "concise", "emoji", "emojis", "format", "formatting", "reply", "replies", "answers",
                                "bullet", "bullets", "verbose", "spelling", "formal", "informal"],
        "project_context": ["project", "deadline", "client", "team", "launch", "milestone", "roadmap", "sprint", "meeting",
                            "stakeholder", "quarter"],
        "privacy_preferences": ["privacy", "private", "confidential", "secret", "share", "sharing", "never tell"],
    ]
    static let timeWords = ["until", "this week", "next week", "tomorrow", "today", "this month", "next month",
                            "temporary", "temporarily", "for now", "for the next", "this year", "deadline"]

    /// A proposal for `text`, among the vault's categories. Sensitivity is at least `hint`.
    public static func propose(_ text: String, categories: [MemoryCategory], hint: Sensitivity? = nil) -> CaptureProposal {
        let lower = text.lowercased()
        let words = Set(lower.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let known = Set(categories.map(\.key))
        var scored: [(String, Int)] = []
        for (key, list) in keywords where known.contains(key) {
            let hits = list.filter { $0.contains(" ") ? lower.contains($0) : words.contains($0) }.count
            if hits > 0 { scored.append((key, hits)) }
        }
        // Custom categories match by name.
        for c in categories where !c.builtin && words.contains(c.name.lowercased()) { scored.append((c.key, 1)) }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let proposal = CaptureProposal(
            title: firstLine, kind: .fact, categoryKeys: scored.prefix(3).map(\.0), sensitivity: hint ?? .low,
            timeLimited: timeWords.contains { lower.contains($0) })
        return proposal.validated(categories: categories, fallbackTitle: text)
    }
}
