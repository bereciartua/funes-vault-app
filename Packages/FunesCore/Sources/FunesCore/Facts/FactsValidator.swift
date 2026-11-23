import Foundation
import FunesProtocol

/// Any JSON value: the Facts task's output is decoded leniently and checked field by field by `FactsValidator`, so a
/// wrong type drops a field or an item, never the whole answer.
public enum FactsJSON: Decodable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), null
    case array([FactsJSON]), object([String: FactsJSON])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([FactsJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: FactsJSON].self)) }
    }

    /// From `JSONSerialization` objects (recorded outputs).
    public init(_ any: Any?) {
        switch any {
        case let s as String: self = .string(s)
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let a as [Any]: self = .array(a.map { FactsJSON($0) })
        case let d as [String: Any]: self = .object(d.mapValues { FactsJSON($0) })
        default: self = .null
        }
    }

    subscript(_ key: String) -> FactsJSON { if case let .object(o) = self { o[key] ?? .null } else { .null } }
    var string: String? { if case let .string(s) = self { s } else { nil } }
    var bool: Bool? { if case let .bool(b) = self { b } else { nil } }
    var int: Int? {
        if case let .number(n) = self, n == n.rounded(), abs(n) < 1e9 { return Int(n) }
        return nil
    }
    var array: [FactsJSON] { if case let .array(a) = self { a } else { [] } }
    var object: [String: FactsJSON]? { if case let .object(o) = self { o } else { nil } }
}

/// A named thing that isn't a person (a pet, a company, a place, a product): stored as an entity of its kind, so it
/// stops a person of the same name (memory processing §11.1).
public struct ExtractedThing: Sendable, Equatable {
    public var name: String
    public var kind: String              // an entity kind: organization, place or thing
    public var quote: String
    public var span: NSRange?
}

/// What validation kept from one call, and what it dropped (reasons and indices only, never text).
public struct FactsValidated: Sendable {
    public var people: [ExtractedPerson] = []
    public var facts: [ExtractedFact] = []
    public var roles: [ExtractedRole] = []
    public var things: [ExtractedThing] = []
    public var dropped: [Drop] = []

    public struct Drop: Sendable, Equatable {
        public var reason: String
        public var index: Int
    }

    /// Entity ids the answer refers to (roster entries it used).
    public var referenced: Set<String> = []
}

/// The Facts task's validation (memory processing §11.3), structure not meaning: a port of `facts.validate` with the
/// secret scanner added. Quotes are checked against the text sent and mapped back to the original.
struct FactsValidator {
    let graph: FactsGraph
    let sent: FactsSentText
    /// Roster ids as the call showed them (`e1…`) → entity ids.
    let roster: [String: String]
    let phrases: [RolePhrase]
    let predicates: [String]
    /// Folded names of known non-person entities written with a capital (they stop a new person of that name).
    let knownThings: Set<String>
    /// Whether the memory is trusted: its pairs match only aliases trusted memories, or the user, gave (§11.4).
    var trusted = true

    var registry: FactsRegistry { graph.registry }

    static let personKind = "person"
    enum Ref: String { case new, different, ambiguous, name, group, none, unknown }
    static let someoneElse = "someone_else"
    static let namePrefix = "name:"

    func inText(_ s: String?) -> Bool { FactsSentText.contains(sent.sent, s ?? "") }
    /// Whether a name the model gives is written within one line of `text` (13e.2). Quote matching tolerates
    /// whitespace, line breaks included, so without this "Note Max" would match a title over a body that opens "Max".
    func onOneLine(_ name: String, in text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { FactsSentText.find(name, in: String($0)) != nil }
    }
    func secret(_ s: String?) -> Bool { s.map { !SecretScanner.scan($0).isEmpty } ?? false }
    func capital(_ s: String) -> Bool { s.contains { $0.isUppercase } }
    /// Whether an organization the model names reads as a name (13e.2 r2): "work" in "a difficult day at work", "the
    /// office", a sentence's opening "The office" or "Mi trabajo" isn't an employer. A name has a capital letter, a digit
    /// or an inner dot ("eBay", "37signals", "bol.com"), isn't a registry word, and isn't only an owner or determiner and
    /// words a workplace is called (the language's workplace and work-noun words, organization predicates' query nouns).
    func namesAnOrganization(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, capital(t) || t.contains(where: \.isNumber) || t.dropFirst().dropLast().contains(".") else { return false }
        if registry.lexicon[t.lowercased()] != nil { return false }
        let words = FactsText.fold(t).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let common = Self.commonOrgWords(registry)
        return words.contains { !common.contains($0) }
    }
    /// The kinds a timeline's holders are (an employer's).
    static func organizationKinds(_ registry: FactsRegistry) -> Set<String> { Set(registry.timelinePredicates.map(registry.kindOf)) }
    /// The words an organization's name can't consist of alone (`namesAnOrganization`), per registry.
    static func commonOrgWords(_ registry: FactsRegistry) -> Set<String> {
        let lang = registry.language
        let kinds = organizationKinds(registry)
        let nouns = registry.predicates.filter { kinds.contains(registry.kindOf($0.id)) }.flatMap { $0.queryNouns ?? [] }
        let all = lang.notNames + lang.owners + lang.ownerWords + lang.anchorDeterminers + (lang.leadRefusedFirst ?? [])
            + (lang.verbNouns ?? []) + nouns
        return Set(all.flatMap { FactsText.fold($0).split(separator: " ").map(String.init) })
    }
    func entity(_ rosterID: String) -> FactsEntity? { roster[rosterID].flatMap { graph.entities[$0] } }
    func isUnnamedGroup(_ e: FactsEntity?) -> Bool { e.map { $0.group != nil && $0.name == nil } ?? false }
    func folded(_ e: FactsEntity) -> Set<String> { Set((trusted ? e.trustedAliases : e.aliases).map { FactsText.fold($0) }) }

    /// A quote's place in the original text, when it's in the text sent and carries no secret; with `holding`, an
    /// occurrence in which that name is a whole word of the text.
    func quoted(_ q: String?, holding name: String? = nil) -> (String, NSRange)? {
        guard let q, !secret(q), let r = name.map({ sent.locate(q, holding: $0) }) ?? sent.locate(q) else { return nil }
        return (sent.slice(r), r)
    }

    func validate(_ out: FactsJSON) -> FactsValidated {
        var v = FactsValidated()
        func drop(_ reason: String, _ i: Int) { v.dropped.append(.init(reason: reason, index: i)) }
        let kinds = FactsPrompt.text.thingKinds

        // Things.
        for (i, t) in out["things"].array.enumerated() {
            guard let name = t["name"].string, let quote = t["quote"].string,
                  let (q, span) = quoted(quote, holding: name), onOneLine(name, in: q) else { drop("thing_quote", i); continue }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if trimmed.count < 2 || registry.lexicon[trimmed.lowercased()] != nil { drop("thing_not_a_name", i); continue }
            guard let kind = t["kind"].string.flatMap({ kinds[$0] }) else { drop("thing_kind", i); continue }
            if Self.organizationKinds(registry).contains(kind), !namesAnOrganization(trimmed) { drop("thing_not_a_name", i); continue }
            if secret(name) { drop("thing_secret", i); continue }
            v.things.append(ExtractedThing(name: name, kind: kind, quote: q, span: span))
        }
        let things = knownThings.union(v.things.filter { capital($0.name) }.map { FactsText.fold($0.name) })

        // People.
        let placeholder = FactsSentText.norm(registry.language.userPlaceholder)
        // People only from a call group that asks for them (a provider not held to the schema may add them anyway).
        let asksForPeople = predicates.contains { registry.kindOf($0) == Self.personKind }
        for (i, p) in (asksForPeople ? out["people"].array : []).enumerated() {
            guard let name = p["name"].string, let quote = p["quote"].string, let ref = p["person"].string,
                  let (q, span) = quoted(quote, holding: name), onOneLine(name, in: q) else { drop("person_quote", i); continue }
            let special = [Ref.new, .different, .ambiguous].map(\.rawValue)
            guard roster[ref] != nil || special.contains(ref) else { drop("person_id", i); continue }
            if FactsSentText.norm(name) == placeholder { continue }
            // The user's own names are never added (§11.9): a namesake keeps a longer name ("Dani Ortiz").
            if graph.userAliases.contains(where: { FactsText.fold($0) == FactsText.fold(name) }) { drop("user_name", i); continue }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if registry.lexicon[trimmed.lowercased()] != nil || (name.first.map { $0.isLowercase } ?? true) || graph.isRoleName(name) {
                drop("not_a_name", i); continue
            }
            if things.contains(FactsText.fold(name)), ref == Ref.new.rawValue || ref == Ref.ambiguous.rawValue {
                drop("named_thing", i); continue
            }
            if secret(name) { drop("person_secret", i); continue }
            var person = ExtractedPerson(name: name, quote: q, person: roster[ref] ?? ref)
            person.span = span
            if let e = roster[ref] { v.referenced.insert(e) }
            v.people.append(person)
        }
        var namesHere = Set(v.people.map { FactsSentText.norm($0.name) })

        // Facts.
        for (i, r) in out["facts"].array.enumerated() {
            guard let pred = r["predicate"].string, predicates.contains(pred) else { drop("predicate", i); continue }
            let kind = registry.kindOf(pred)
            var entity = r["entity"].string ?? ""
            var name = r["name"].string
            if entity.hasPrefix(Self.namePrefix) {
                if name?.isEmpty ?? true { name = String(entity.dropFirst(Self.namePrefix.count)) }
                entity = Ref.name.rawValue
            }
            guard let polarity = r["polarity"].string.flatMap(FactsPrompt.Polarity.init) else { drop("polarity", i); continue }
            var fields: [String: String] = [:]
            for f in ["time", "start", "end", "preceded_by", "followed_by", "also_called"] {
                guard let s = r[f].string, !s.isEmpty else { continue }
                if !inText(s) || (["preceded_by", "followed_by", "also_called"].contains(f) && !onOneLine(s, in: sent.sent)) {
                    drop(f + "_absent", i); continue
                }
                if secret(s) { drop(f + "_secret", i); continue }
                if f == "also_called", Self.organizationKinds(registry).contains(registry.kindOf(pred)), !namesAnOrganization(s) { drop("also_called_not_a_name", i); continue }
                fields[f] = s
            }
            var quals: [String: String] = [:]
            let spec = registry.predicate(pred)?.qualifiers ?? [:]
            for (k, value) in r["qualifiers"].object ?? [:] {
                guard let s = value.string, !s.isEmpty, k != FactsPrompt.labelKey, let q = spec[k] else { continue }
                if let values = q.values {
                    if !values.contains(s) { drop("qualifier_value", i); continue }
                } else if !inText(s) {
                    drop("qualifier_not_in_text", i); continue
                }
                if secret(s) { drop("qualifier_secret", i); continue }
                quals[k] = s
            }
            guard let (quote, span) = quoted(r["quote"].string) else { drop("fact_quote", i); continue }
            var entityID = entity
            if kind == Self.personKind {
                if entity == Ref.name.rawValue {
                    guard let n = name, namesHere.contains(FactsSentText.norm(n)) else { drop("fact_name", i); continue }
                } else if let e = roster[entity] {
                    entityID = e
                    v.referenced.insert(e)
                } else if entity != Ref.group.rawValue && entity != Ref.none.rawValue {
                    drop("fact_id", i); continue
                }
            } else {
                let nm = name ?? ""
                let ph = graph.placeholder(pred, nm)
                if nm.isEmpty || (ph == nil && (!inText(nm) || !onOneLine(nm, in: sent.sent))) { drop("fact_object", i); continue }
                if ph == nil, namesHere.contains(FactsSentText.norm(nm)) { drop("fact_kind", i); continue }
                if ph == nil, Self.organizationKinds(registry).contains(kind), !namesAnOrganization(nm) { drop("fact_not_a_name", i); continue }
                if secret(nm) { drop("fact_secret", i); continue }
                entityID = Ref.name.rawValue
                name = ph ?? nm
            }
            var label = r["label"].string
            if let l = label, !inText(l) || secret(l) { label = nil; drop("label_not_in_text", i) }
            let count = r["count"].int.flatMap { $0 >= 0 ? $0 : nil }
            var f = ExtractedFact(predicate: pred, name: name ?? "", entity: entityID, label: label, quote: quote,
                                  positive: polarity == .positive,
                                  status: r["status"].string.flatMap(FactAssertion.Status.init) ?? .unknown,
                                  deceased: r["deceased"].bool ?? false, only: r["only"].bool ?? false, count: count,
                                  time: fields["time"], start: fields["start"], end: fields["end"],
                                  precededBy: fields["preceded_by"], followedBy: fields["followed_by"],
                                  alsoCalled: fields["also_called"], qualifiers: quals)
            f.span = span
            v.facts.append(f)
        }

        // Roles.
        var roles: [(id: Int, ref: String)] = []
        for (i, x) in out["roles"].array.enumerated() {
            guard let id = x["id"].string, id.hasPrefix("r"), let n = Int(id.dropFirst()), n > 0, n <= phrases.count,
                  let ref = x["refers_to"].string else { drop("mention_ref", i); continue }
            let named = ref.hasPrefix(Self.namePrefix) && namesHere.contains(FactsSentText.norm(String(ref.dropFirst(Self.namePrefix.count))))
            let fixed = [Ref.group.rawValue, Self.someoneElse, Ref.unknown.rawValue].contains(ref)
            guard roster[ref] != nil || fixed || named else { drop("mention_ref", i); continue }
            roles.append((n - 1, ref))
        }

        // Pairs code applies (memory processing §11.3): "Maria is my sister", "my sister Maria".
        for (i, ph) in phrases.enumerated() {
            guard let paired = ph.paired, !graph.isRoleName(paired) else { continue }
            let ref = roles.first { $0.id == i }?.ref
            let e = ref.flatMap(entity)
            let loose = ref == nil || ref == Ref.group.rawValue || ref == Ref.unknown.rawValue || isUnnamedGroup(e)
            let onName = (ref.map { $0.hasPrefix(Self.namePrefix) && FactsSentText.norm(String($0.dropFirst(Self.namePrefix.count))) == FactsSentText.norm(paired) } ?? false)
                || (e.map { $0.name != nil && folded($0).contains(FactsText.fold(paired)) } ?? false)
            guard loose || onName, inText(paired), !secret(paired) else { continue }
            let word = ph.word
            var base = ExtractedFact(predicate: ph.predicate, name: paired, entity: Ref.name.rawValue,
                                     label: inText(word) ? word : nil, quote: ph.surface)
            base.span = NSRange(location: ph.start, length: ph.end - ph.start)
            if onName {
                let entityID = ref.flatMap { roster[$0] }
                let has = v.facts.contains { f in
                    f.predicate == ph.predicate && f.positive
                        && (f.entity == entityID || (f.entity == Ref.name.rawValue && FactsSentText.norm(f.name) == FactsSentText.norm(paired)))
                }
                if !has {
                    if let entityID { base.entity = entityID; v.referenced.insert(entityID) }
                    v.facts.append(base)
                    drop("paired_relation_added", i)
                }
                continue
            }
            if !namesHere.contains(FactsSentText.norm(paired)) {
                let known = roster.values.compactMap { graph.entities[$0] }
                    .filter { $0.name != nil && folded($0).contains(FactsText.fold(paired)) }
                var p = ExtractedPerson(name: paired, quote: paired, person: known.count == 1 ? known[0].id : Ref.new.rawValue)
                p.span = sent.locate(paired)
                if known.count == 1 { v.referenced.insert(known[0].id) }
                v.people.append(p)
                namesHere.insert(FactsSentText.norm(paired))
            }
            roles.removeAll { $0.id == i }
            roles.append((i, Self.namePrefix + paired))
            if !v.facts.contains(where: { $0.entity == Ref.name.rawValue && FactsSentText.norm($0.name) == FactsSentText.norm(paired) && $0.predicate == ph.predicate }) {
                v.facts.append(base)
            }
            drop("paired_applied", i)
        }

        // A role phrase inside a denial of the same predicate refers to nobody.
        for f in v.facts where !f.positive {
            guard let span = f.span else { continue }
            for (i, ph) in phrases.enumerated() where ph.predicate == f.predicate
                && ph.start >= span.location && ph.start < span.location + span.length {
                roles.removeAll { $0.id == i }
                roles.append((i, Self.someoneElse))
                drop("denial", i)
            }
        }
        v.roles = roles.map { r in
            if let e = roster[r.ref] { v.referenced.insert(e); return ExtractedRole(phrase: r.id, refersTo: e) }
            return ExtractedRole(phrase: r.id, refersTo: r.ref)
        }
        return v
    }
}
