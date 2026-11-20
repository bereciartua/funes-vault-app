import FunesCore

/// English words for learned facts (companion protocol §4), for tests and a Mac that supplies none: the Mac's own
/// wording comes from its String Catalog (`CompanionServices.factsWording`).
public struct EnglishFactsWording: FactsWording {
    public init() {}

    public func whyLine(_ line: WhyLine) -> String {
        switch line.form {
        case let .role(surface, name): "\(surface) → \(name)"
        case let .name(name, attribute): "\(name), \(attribute)"
        case let .candidates(attribute): "\(attribute); Funes isn't sure which"
        case let .ambiguous(name): "\(name); Funes isn't sure who"
        case let .group(attribute): attribute
        case let .timeline(noun, op, anchor, answer): anchor.map { "your \(noun) \(op) \($0) → \(answer)" } ?? "your \(noun) → \(answer)"
        }
    }

    public func claimWhy(_ line: WhyLine) -> String {
        switch line.form {
        case let .name(name, attribute): "\(name) is \(attribute)"
        case let .timeline(noun, op, anchor, answer):
            anchor.map { "From your history: your \(noun) \(op) \($0) was \(answer)" } ?? "From your history: \(answer)"
        default: whyLine(line)
        }
    }

    public func label(_ c: FactsCorrection) -> String {
        c.target.what == .name ? "Not \(c.name ?? "this")" : "Not this"
    }

    public func note(_ note: TimelineNote) -> String {
        note.anchor.map { "Funes can't tell which \(note.noun) came \(note.op) \($0)" } ?? "Funes can't tell which \(note.noun) it was"
    }
}
