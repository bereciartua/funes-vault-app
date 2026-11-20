import FunesCore
import SwiftUI

/// A why line's words (04-ux-mac.md, Vault ▸ Why lines): Funes's own words from the String Catalog, around the
/// registry's phrases ("your sister", "job") and the names and words the memories use.
enum WhyLineText {
    /// "my sister → Maria (only sister Funes knows)", "Maria, your sister", "your sister; Funes isn't sure which",
    /// "your job before Initech → Acme (from the dates)".
    static func text(_ line: WhyLine) -> String {
        let basis = basisWords(line)
        var out: String
        switch line.form {
        case let .role(surface, name):
            out = basis.map { String(localized: "\(surface) → \(name) (\($0))", comment: "Why line: the memory's role phrase, who it is, and why") }
                ?? String(localized: "\(surface) → \(name)", comment: "Why line: the memory's role phrase and who it is")
        case let .name(name, attribute):
            out = basis.map { String(localized: "\(name), \(attribute) (\($0))", comment: "Why line: a name, who they are to you, and why") }
                ?? String(localized: "\(name), \(attribute)", comment: "Why line: a name and who they are to you")
        case let .candidates(attribute):
            out = String(localized: "\(attribute); Funes isn't sure which", comment: "Why line: several people fit the role")
        case let .ambiguous(name):
            out = String(localized: "\(name); Funes isn't sure who", comment: "Why line: two known people share the name")
        case let .group(attribute):
            out = attribute
        case let .timeline(noun, op, anchor, answer):
            let what = anchor.map { String(localized: "your \(noun) \(op) \($0)", comment: "Why line: e.g. your job before Initech") }
                ?? String(localized: "your \(noun)", comment: "Why line: e.g. your job")
            out = basis.map { String(localized: "\(what) → \(answer) (\($0))", comment: "Why line: a timeline answer and why") }
                ?? String(localized: "\(what) → \(answer)", comment: "Why line: a timeline answer")
        }
        if line.untrusted, line.basis != .link(.untrusted) {
            out += " " + String(localized: "(from text you didn't write)")
        }
        return out
    }

    /// The basis in words, nil where the line says it already (or a name the memory itself gives).
    static func basisWords(_ line: WhyLine) -> String? {
        let label = line.label
        switch line.basis {
        case let .link(b):
            switch b {
            case .confirmed: return String(localized: "you said so", comment: "Why line basis")
            case .named:
                if case .name = line.form { return nil }
                return String(localized: "the memory says so", comment: "Why line basis")
            case .statedUnique: return String(localized: "your only \(label)", comment: "Why line basis: e.g. your only sister")
            case .soleKnown: return String(localized: "only \(label) Funes knows", comment: "Why line basis: e.g. only sister Funes knows")
            case .context: return String(localized: "from the memory", comment: "Why line basis")
            case .inferred: return String(localized: "probably", comment: "Why line basis")
            case .untrusted: return String(localized: "from text you didn't write")
            default: return nil
            }
        case let .timeline(b):
            switch b {
            case .ordered: return String(localized: "from the dates", comment: "Why line basis: a timeline answer")
            case .stated: return String(localized: "a memory says so", comment: "Why line basis: a timeline answer")
            case .inferred: return String(localized: "probably", comment: "Why line basis")
            case .gap: return String(localized: "with a gap", comment: "Why line basis: a timeline answer")
            default: return nil
            }
        }
    }

    /// What an inferred claim rests on that its quote doesn't say: "Maria is your sister: only sister Funes knows",
    /// "From your history: your job before Initech was Acme".
    static func claimWhy(_ line: WhyLine) -> String {
        let basis = basisWords(line)
        switch line.form {
        case let .name(name, attribute):
            return basis.map { String(localized: "\(name) is \(attribute): \($0)", comment: "Inferred claim: who they are to you, and why") }
                ?? String(localized: "\(name) is \(attribute)", comment: "Inferred claim: who they are to you")
        case let .timeline(noun, op, anchor, answer):
            if let anchor {
                return String(localized: "From your history: your \(noun) \(op) \(anchor) was \(answer)",
                              comment: "Inferred claim: a timeline answer, e.g. your job before Initech was Acme")
            }
            return String(localized: "From your history: \(answer)", comment: "Inferred claim: a timeline answer")
        case let .ambiguous(name):
            return String(localized: "Funes linked this memory to \(name)", comment: "Inferred claim: a link the memory doesn't state")
        default:
            return text(line)
        }
    }

    /// A correction's button: "Not Maria", "Not This".
    static func label(_ c: FactsCorrection) -> String {
        if c.target.what == .name, let name = c.name {
            return String(localized: "Not \(name)", comment: "Why line correction: this memory isn't about them")
        }
        return String(localized: "Not This", comment: "Why line correction: the fact is wrong")
    }

    /// Not this's question for a claim's fact: "Maria isn't your sister?".
    static func notThisQuestion(_ c: FactsCorrection) -> String {
        if let name = c.name, let attribute = c.attribute {
            return String(localized: "\(name) isn't \(attribute)?", comment: "Not this: confirm the fact is wrong")
        }
        return String(localized: "Mark this as wrong?")
    }

    /// The undecidable-timeline note: "Funes can't tell which job came before Acme".
    static func note(_ note: TimelineNote) -> String {
        if let anchor = note.anchor {
            return String(localized: "Funes can't tell which \(note.noun) came \(note.op) \(anchor)",
                          comment: "Answer card: a timeline question Funes can't decide, e.g. which job came before Acme")
        }
        return String(localized: "Funes can't tell which \(note.noun) it was", comment: "Answer card: a timeline question Funes can't decide")
    }

    /// "Maria isn't your sister?": Not this's question.
    static func notThisQuestion(_ line: WhyLine) -> String {
        if let name = line.notName?.name, case let .name(_, attribute) = line.form {
            return String(localized: "\(name) isn't \(attribute)?", comment: "Not this: confirm the fact is wrong")
        }
        if let name = line.notName?.name {
            return String(localized: "\(name) isn't your \(line.label)?", comment: "Not this: confirm the fact is wrong")
        }
        return String(localized: "Mark this as wrong?")
    }
}

/// Learned facts as the phone shows them (companion protocol §4): the Mac's words, from this String Catalog.
struct MacFactsWording: FactsWording {
    func whyLine(_ line: WhyLine) -> String { WhyLineText.text(line) }

    func claimWhy(_ line: WhyLine) -> String { WhyLineText.claimWhy(line) }

    func label(_ c: FactsCorrection) -> String { WhyLineText.label(c) }

    func note(_ note: TimelineNote) -> String { WhyLineText.note(note) }
}

/// The why line under a result's preview: a link glyph, the line, and its ⋯ menu with the corrections.
struct WhyLineRow: View {
    let line: WhyLine
    let notName: (WhyLine.NotName) -> Void
    let notThis: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "link").font(.caption2).accessibilityHidden(true)
            Text(WhyLineText.text(line)).lineLimit(1)
            if line.notName != nil || line.notThis != nil {
                Menu {
                    WhyLineCorrections(line: line, notName: notName, notThis: notThis)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(String(localized: "Correct this"))
                .accessibilityLabel(String(localized: "Correct this"))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// **Not <name>** and **Not this**, for the why line's menu and the row's context menu.
struct WhyLineCorrections: View {
    let line: WhyLine
    let notName: (WhyLine.NotName) -> Void
    let notThis: () -> Void

    var body: some View {
        if let target = line.notName {
            Button(String(localized: "Not \(target.name)", comment: "Why line correction: this memory isn't about them")) { notName(target) }
        }
        if line.notThis != nil {
            Button(String(localized: "Not This", comment: "Why line correction: the fact is wrong")) { notThis() }
        }
    }
}
