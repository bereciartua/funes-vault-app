import Foundation

// 13e.2's words (memory processing §10.3–§10.4): the rows as the answer prompt gives them, and the checked line. Kept
// out of Facts/, whose code carries no language (the registry's vocabulary test).

extension TimelineRows {
    /// The `<work_history>` block (§10.3), entities by alias; the predicate's id names it.
    public func block(tag: String = "work_history") -> String {
        var lines = ["<\(tag) predicate=\"\(predicate)\">"]
        for r in rows {
            var attrs = "entity=\"\(r.alias)\" name=\"\(Self.attr(r.name))\""
            if !r.renames.isEmpty { attrs += " also_called=\"\(Self.attr(r.renames.joined(separator: "; ")))\"" }
            if let s = r.slot { attrs += " slot=\"\(Self.attr(s))\"" }
            attrs += " start=\"\(r.start)\" end=\"\(r.ongoing ? "ongoing" : r.end)\""
            if r.inferredEnd { attrs += " end_inferred=\"yes\"" }
            lines.append("<job \(attrs)/>")
        }
        lines.append("</\(tag)>")
        return lines.joined(separator: "\n")
    }

    /// How a checked line names an entity: its row's name, with its other names ("Brindle Arc (also called Brindle
    /// Quay)"), else nil (the caller's fallback). Never "formerly": which name is newer is a reading, not a statement.
    public func label(_ id: String, graph: FactsGraph) -> String? {
        guard let r = row(for: id, graph: graph) else { return nil }
        return r.renames.isEmpty ? r.name : "\(r.name) (also called \(r.renames.joined(separator: ", ")))"
    }

    static func attr(_ v: String) -> String {
        v.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
    }
}

/// The checked line and the "not sure" reason, worded by code from the validated fields (§10.4). The default words are
/// English; the Mac's String Catalog may word them instead (`TimelineCheckWording` is data the app can replace).
public struct TimelineCheckWording: Sendable {
    public var line: @Sendable (TimelineCheckResult, _ name: (String?) -> String?, _ noun: String) -> String

    public init(line: @escaping @Sendable (TimelineCheckResult, _ name: (String?) -> String?, _ noun: String) -> String) {
        self.line = line
    }

    public static let english = TimelineCheckWording { r, name, noun in
        // The anchor as the check read it: one of its stints when it was held more than once (13e.2's fix round).
        let anchor: String? = name(r.anchor).map { a in
            guard let n = r.stint, r.stintCount > 1 else { return a }
            return n == 1 ? "your first stint at \(a)" : n == r.stintCount && n == 2 ? "your return to \(a)" : "stint \(n) at \(a)"
        }
        let answer = name(r.answer) ?? "unknown"
        func started() -> String {
            guard let a = name(r.anchor) else { return "then" }
            guard let n = r.stint, r.stintCount > 1 else { return "you started at \(a)" }
            return n == 1 ? "you first started at \(a)" : n == 2 ? "you returned to \(a)" : "stint \(n) at \(a) began"
        }
        switch (r.op, r.verdict) {
        case ("at_start", .agrees), ("at_start", .agreesTrusted):
            return "Just before \(started()), you were still at \(answer)."
        case ("ended_before", .agrees), ("ended_before", .agreesTrusted):
            return "Before \(started()), you had already left \(answer)."
        case ("first", .agrees), ("first", .agreesTrusted):
            return "The earliest \(noun) in your notes: \(answer)."
        case ("at_start", _) where r.reason != .noComparison && r.reason != .invalid:
            return "Funes can't tell which \(noun) you still had just before \(started())."
        case ("ended_before", _) where r.reason != .noComparison && r.reason != .invalid:
            return "Funes can't tell which \(noun) you had already left before \(started())."
        case ("first", _) where r.reason != .noComparison && r.reason != .invalid:
            return "Funes can't tell which \(noun) you had first."
        default: break
        }
        func when() -> String {
            switch r.op {
            case "before", "previous" where r.op == "before" || anchor != nil:
                return anchor.map { "before \($0)" } ?? r.anchorDate.map { "before \($0)" } ?? "before then"
            case "after": return anchor.map { "after \($0)" } ?? r.anchorDate.map { "after \($0)" } ?? "after then"
            case "in": return r.anchorDate.map { ($0.count == 10 ? "on " : "in ") + $0 } ?? "then"   // a day takes "on"
            case "between": return "between \(r.anchorDate ?? "?") and \(r.endDate ?? "?")"
            case "current": return "now"
            default: return "before your current \(noun)"
            }
        }
        switch r.verdict {
        case .agrees, .agreesTrusted:
            var w = when()
            w = w.prefix(1).uppercased() + w.dropFirst()
            var line = "\(w): \(answer)"
            if r.basis == .gap { line += ", with a gap between them" }
            if r.op == "current" { line += ", as far as your memories say" }
            return line + "."
        case .notSure, .disagrees:
            switch r.reason {
            case .stints?:
                guard let anchor else { fallthrough }
                let parts = r.stints.enumerated().map { i, e in "\(i == 0 ? "your first" : i == 1 ? "your second" : "stint \(i + 1)") stint: \(name(e) ?? "can't tell")" }
                return "Funes can't tell which stint at \(anchor) you mean (\(parts.joined(separator: "; ")))."
            case .noComparison?, .invalid?:
                return "Funes couldn't check this against your work history."
            default:
                return "Funes can't tell which \(noun) you had \(when())."
            }
        }
    }
}

