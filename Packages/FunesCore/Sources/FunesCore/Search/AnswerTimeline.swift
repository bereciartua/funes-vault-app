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
        let anchor = name(r.anchor)
        let answer = name(r.answer) ?? "unknown"
        func when() -> String {
            switch r.op {
            case "before", "previous" where r.op == "before" || anchor != nil:
                return anchor.map { "before \($0)" } ?? r.anchorDate.map { "before \($0)" } ?? "before then"
            case "after": return anchor.map { "after \($0)" } ?? r.anchorDate.map { "after \($0)" } ?? "after then"
            case "in": return r.anchorDate.map { "in \($0)" } ?? "then"
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
                let parts = r.stints.enumerated().map { i, e in "\(i == 0 ? "your first" : i == 1 ? "your second" : "stint \(i + 1)") stint: \(name(e) ?? "unknown")" }
                return "Funes can't tell which stint at \(anchor) you mean (\(parts.joined(separator: "; ")))."
            case .noComparison?, .invalid?:
                return "Funes couldn't check this against your work history."
            default:
                return "Funes can't tell which \(noun) you had \(when())."
            }
        }
    }
}

