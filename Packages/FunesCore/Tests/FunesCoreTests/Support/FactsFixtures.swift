import Foundation
@testable import FunesCore

/// Helpers for the time-model tests ported from Spike H3/H3b (`spikes/people/test_facts.py`, `test_temporal.py`).
/// Predicates are picked by their registry properties, never by name.
enum FX {
    static let registry = FactsRegistry.bundled
    static var dated: String { registry.timelinePredicates[0] }
    static var slot: String { registry.predicate(dated)!.slot! }
    static var slotValues: [String] { registry.predicate(dated)!.qualifiers[slot]!.values! }
    static var emp: String { slotValues[0] }
    static var own: String { slotValues[1] }

    static func personPredicate(where test: (FactsRegistry.Predicate) -> Bool, in reg: FactsRegistry = registry) -> String {
        reg.predicates.first { $0.objectKind == "person" && test($0) }!.id
    }

    static var personExclusive: String { personPredicate { $0.exclusive } }
    static var personSuccession: String { personPredicate { $0.succession && !$0.exclusive } }

    /// A plain word of a predicate: no class, not plural.
    static func word(_ pred: String, in reg: FactsRegistry = registry) -> String {
        reg.predicate(pred)!.lexicon.first { $0.cls == nil && $0.plural != true }!.words[0]
    }

    /// A registry derived from the bundled JSON by editing it as data.
    static func registry(editing edit: (inout [String: Any]) -> Void) throws -> FactsRegistry {
        var json = try JSONSerialization.jsonObject(with: FactsRegistry.bundledData) as! [String: Any]
        edit(&json)
        return try FactsRegistry.decode(try JSONSerialization.data(withJSONObject: json))
    }

    /// Edits one predicate of a registry's JSON.
    static func editPredicate(_ json: inout [String: Any], _ id: String, _ edit: (inout [String: Any]) -> Void) {
        var preds = json["predicates"] as! [[String: Any]]
        let i = preds.firstIndex { $0["id"] as? String == id }!
        edit(&preds[i])
        json["predicates"] = preds
    }
}

/// A canned extraction, as the spike's `fact()` built it.
func fact(_ pred: String, _ name: String, _ start: String? = nil, _ end: String? = nil,
          status: FactAssertion.Status = .unknown, slot: String? = nil, precededBy: String? = nil,
          followedBy: String? = nil, label: String? = nil, time: String? = nil, quote: String? = nil,
          positive: Bool = true, deceased: Bool = false) -> ExtractedFact {
    ExtractedFact(predicate: pred, name: name, label: label, quote: quote, positive: positive, status: status,
                  deceased: deceased, time: time, start: start, end: end, precededBy: precededBy, followedBy: followedBy,
                  qualifiers: slot.map { [FX.slot: $0] } ?? [:])
}

/// One memory's fact for `stateWith`: trusted and written 2026-01-01 unless stated.
struct FactRow {
    var fact: ExtractedFact
    var trusted = true
    var written = "2026-01-01"
}

protocol FactRowConvertible { var row: FactRow { get } }

extension FactRow: FactRowConvertible { var row: FactRow { self } }

extension ExtractedFact: FactRowConvertible {
    var row: FactRow { FactRow(fact: self) }
    func at(_ written: String) -> FactRow { FactRow(fact: self, written: written) }
    var untrusted: FactRow { FactRow(fact: self, trusted: false) }
    func untrusted(at written: String) -> FactRow { FactRow(fact: self, trusted: false, written: written) }
}

/// A graph built from canned facts, one memory each (the memory's text is the entity's name).
func stateWith(_ rows: [FactRowConvertible], registry: FactsRegistry = FX.registry) -> FactsGraph {
    var s = FactsGraph(registry: registry)
    for (i, r) in rows.map(\.row).enumerated() {
        let mem = FactsMemory(id: "m\(i)", text: r.fact.name, written: r.written, trusted: r.trusted)
        s.apply(mem, facts: [r.fact])
    }
    return s
}

/// A graph of person facts, one memory each, linking names to the people already known.
func peopleState(_ pred: String, _ rows: [(String, String?, String?, FactAssertion.Status, String)]) -> FactsGraph {
    var s = FactsGraph(registry: FX.registry)
    for (i, (nm, st, en, status, written)) in rows.enumerated() {
        let mem = FactsMemory(id: "m\(i)", text: "\(nm) memory \(i)", written: written, trusted: true)
        let known = s.entities.values.first { $0.name == nm }
        s.apply(mem, people: [ExtractedPerson(name: nm, person: known?.id ?? "new")],
                facts: [fact(pred, nm, st, en, status: status)], roster: known.map { [$0.id] } ?? [])
    }
    return s
}

extension FactsGraph {
    func ent(_ name: String, _ pred: String = FX.dated) -> String { entityMatches(pred, name)[0] }
    func name(_ id: String?) -> String? { id.flatMap { entities[$0]?.name } }

    /// Episodes by entity name (the last one wins, as the spike's dict did).
    func episodesByName(_ pred: String = FX.dated) -> [String: Episode] {
        var out: [String: Episode] = [:]
        for e in episodes(pred) { if let n = name(e.entity) { out[n] = e } }
        return out
    }

    func episodes(of entityName: String, _ pred: String = FX.dated) -> [Episode] {
        episodes(pred).filter { name($0.entity) == entityName }
    }

    func beforeName(_ x: String, _ q: String = "") -> (String?, TimelineBasis) {
        let r = before(FX.dated, .entity(ent(x)), query: q)
        return (name(r.entity), r.basis)
    }

    func afterName(_ x: String, _ q: String = "") -> (String?, TimelineBasis) {
        let r = after(FX.dated, .entity(ent(x)), query: q)
        return (name(r.entity), r.basis)
    }

    /// Resolves the first role phrase of a text written on a date.
    mutating func resolveText(_ text: String, _ written: String, id: String = "q") -> (String?, LinkBasis) {
        let mem = FactsMemory(id: id, text: text, written: written)
        let r = resolve(mem, rolePhrases(text)[0])
        return (name(r.entity), r.basis)
    }

    func ask(_ q: String) -> TimelineAnswer? { intent(q).map { answer($0, query: q) } }
}

extension TimelineAnswer {
    var isAmbiguous: Bool { entities.isEmpty && basis == .ambiguous }
}
