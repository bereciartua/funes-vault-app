import Foundation
import FunesProtocol
import GRDB
import Synchronization
import Testing
@testable import FunesCore

/// The Facts task end to end on scripted model answers (memory processing §11.3, §11.9): the sent text and its offset
/// map, validation rules the spike didn't have, the apply's checks, things, ambiguous names, alias provenance, code-only
/// links, the router's guardrails and Activity. No live calls.
@Suite(.serialized) struct FactsExtractorTests {
    let v: TestVault
    let people: String
    let work: String
    let user = ["Dani Ortega", "Dani"]

    init() throws {
        v = try TestVault()
        let reg = FactsRegistry.bundled
        people = reg.callGroups.keys.sorted().first { FactsPrompt.hasPeople($0, reg) }!
        work = reg.predicate(reg.timelinePredicates[0])!.callGroup
    }

    var sibling: String { FX.personPredicate { $0.lexicon.contains { $0.words.contains("sister") } } }
    var employer: String { FX.dated }

    /// A provider whose answer is a function of the request; it records every request.
    final class Scripted: GenerationProvider, @unchecked Sendable {
        let id: ProviderID
        let locality: Locality
        let modelID = "scripted"
        let answer: @Sendable (StructuredRequest<FactsJSON>) -> [String: Any]
        let seen = Mutex<[(instructions: String, prompt: String)]>([])

        init(locality: Locality = .cloud, _ answer: @escaping @Sendable (StructuredRequest<FactsJSON>) -> [String: Any]) {
            id = locality == .cloud ? "anthropic" : "ollama"
            self.locality = locality
            self.answer = answer
        }

        func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
            seen.withLock { $0.append((request.instructions, request.prompt)) }
            let r = StructuredRequest<FactsJSON>(instructions: request.instructions, prompt: request.prompt, schema: request.schema)
            var out = answer(r)
            for k in ["facts", "roles", "things"] where out[k] == nil { out[k] = [] as [Any] }
            if request.schema.json.contains("\"people\""), out["people"] == nil { out["people"] = [] as [Any] }
            let data = try JSONSerialization.data(withJSONObject: out)
            return (try HTTPClient.decode(String(decoding: data, as: UTF8.self), as: T.self), ProviderUsage(requests: 1, inputTokens: 10, outputTokens: 5))
        }
    }

    static func fact(_ quote: String, _ predicate: String, _ name: String, entity: String = "name", label: String? = nil,
                     polarity: String = "positive", status: String = "unknown", start: String? = nil,
                     qualifiers: [String: Any] = [:]) -> [String: Any] {
        ["quote": quote, "predicate": predicate, "entity": entity, "name": name, "label": label ?? NSNull(), "polarity": polarity,
         "status": status, "deceased": false, "only": false, "count": NSNull(), "time": NSNull(), "start": start ?? NSNull(),
         "end": NSNull(), "preceded_by": NSNull(), "followed_by": NSNull(), "also_called": NSNull(), "qualifiers": qualifiers]
    }

    func extractor(_ provider: (any GenerationProvider)?, cap: CloudRequestCap? = nil, allowed: Bool = true,
                   limit: CloudLimit = .upTo(.internal), activity: InMemoryActivityLog = InMemoryActivityLog()) -> FactsExtractor {
        let clock = FactsHarness.Clock()
        var x = FactsExtractor(store: v.store, router: ModelRouter(classifier: nil, onDevice: nil, cloudLimit: limit, cap: cap,
                                                                   factsModel: provider),
                               activity: activity, userAliases: user)
        x.unfilteredRostersAllowed = allowed
        x.clock = { clock.now() }
        return x
    }

    func memory(_ text: String, sensitivity: Sensitivity = .low, source: MemorySource? = nil, days: Double = 0) throws -> String {
        let (title, body) = FactsHarness.split(text)
        let m = try v.memory(title, body, sensitivity: sensitivity, now: t0.plus(days: days))
        if let source {
            try v.store.writer.write { db in
                try db.execute(sql: "UPDATE memory SET source = ?, trust = ? WHERE id = ?",
                               arguments: [source.rawValue, source == .agentWrite ? "untrusted" : "trusted", m.id.db])
            }
        }
        return m.id.db
    }

    func load() throws -> FactsGraph { try v.store.writer.read { db in try FactStore.load(db, userAliases: user).graph } }
    func count(_ sql: String) throws -> Int { try v.count(sql) }

    // MARK: The migration

    @Test func aVersion9VaultKeepsItsAliasEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "funes-v9-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "vault.sqlite")
        do {
            let queue = try DatabaseQueue(path: file.path)
            try Schema.migrator.migrate(queue, upTo: "v9_facts")
            try await queue.write { db in
                let m = try MemoryStore.insert(db, MemoryDraft(title: "Ana", body: "Ana called.", kind: .fact, categoryKeys: ["personal_preferences"],
                                                               sensitivity: .low), actor: .user, now: t0)
                try db.execute(sql: "INSERT INTO entity (id, kind, name, created_at, updated_at) VALUES ('e1', 'person', 'Ana', ?, ?)", arguments: [t0, t0])
                try db.execute(sql: "INSERT INTO entity_alias (id, entity_id, alias, normalized) VALUES ('a1', 'e1', 'Ana', 'ana')")
                try db.execute(sql: """
                    INSERT INTO alias_evidence (alias_id, memory_id, memory_version, span_start, span_end, quote, sensitivity, trust)
                    VALUES ('a1', ?, 1, 0, 3, 'Ana', 1, 'trusted')
                    """, arguments: [m.id.db])
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let store = try VaultStore.open(directory: directory)
        let row = try await store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT alias_id || ' ' || call_group || '|' || source FROM alias_evidence")
        }
        #expect(row == "a1 |model")
    }

    // MARK: The sent text

    @Test func theUsersNamesAreReplacedAndQuotesMapBack() {
        let t = FactsSentText("Dani told Lucía “hi”.  Dani Ortega's sister", userAliases: user, registry: .bundled)
        #expect(t.sent == "the user told Lucía “hi”.  the user's sister")
        let r = t.locate("THE USER told lucía \"hi\". the user's")!
        #expect(t.slice(r) == "Dani told Lucía “hi”.  Dani Ortega's")
        #expect(t.locate("the user's sister").map(t.slice) == "Dani Ortega's sister")
        #expect(t.locate("") == nil && t.locate("   ") == nil && t.locate("nowhere") == nil)
        #expect(t.toSent(t.toOriginal(10)) == 10)
    }

    // MARK: Validation beyond the spike

    func validate(_ text: String, _ out: [String: Any], group: String? = nil) -> FactsValidated {
        let g = FactsGraph(userAliases: user)
        let preds = FactsRegistry.bundled.groupPredicates(group ?? people)
        return FactsValidator(graph: g, sent: FactsSentText(text, userAliases: user, registry: .bundled), roster: [:],
                              phrases: g.rolePhrases(text, predicates: Set(preds)), predicates: preds, knownThings: [])
            .validate(FactsJSON(out))
    }

    @Test func secretsWrongTypesAndValuesOutsideAPredicatesEnumAreDropped() {
        let key = "sk-ant-api03-" + String(repeating: "a", count: 90)
        let text = "My sister Maria works with \(key) at Acme."
        var v1 = validate(text, ["people": [["name": key, "quote": text, "person": "new"], ["name": "Maria", "quote": "My sister Maria", "person": "new"]],
                                 "facts": [Self.fact("My sister Maria", sibling, "Maria", label: "sister"),
                                           Self.fact("My sister Maria", sibling, "Maria", polarity: "maybe")]])
        #expect(v1.people.map(\.name) == ["Maria"])
        #expect(v1.dropped.contains { $0.reason == "person_quote" } && v1.dropped.contains { $0.reason == "polarity" })
        #expect(v1.facts.count == 1 && v1.facts[0].span == NSRange(location: 0, length: 15))
        let slot = FX.slot
        let wtext = "I joined Acme in 2019 as a designer."
        v1 = validate(wtext, ["facts": [Self.fact("I joined Acme in 2019", employer, "Acme", start: "2019",
                                                  qualifiers: [slot: "astronaut", "title": "designer"])]], group: work)
        #expect(v1.facts.first?.qualifiers[slot] == nil && v1.facts.first?.qualifiers["title"] == "designer")
        #expect(v1.dropped.contains { $0.reason == "qualifier_value" })
        // A label that is a secret goes; the fact stays.
        let ltext = "My sister \(key) is here."
        v1 = validate(ltext, ["facts": [Self.fact("My sister \(key) is here.", sibling, "x", entity: "group", label: key)]])
        #expect(v1.facts.isEmpty)       // its quote carries the secret
    }

    @Test func aCountIsANonNegativeIntegerAndAnUnknownStatusIsUnknown() {
        var f = Self.fact("I have two sisters", sibling, "", entity: "group", status: "sometimes")
        f["count"] = -2
        let v1 = validate("I have two sisters.", ["facts": [f]])
        #expect(v1.facts.first?.count == nil && v1.facts.first?.status == .unknown)
    }

    // MARK: Apply

    @Test func aMemoryEditedDuringTheCallIsNotApplied() async throws {
        let id = try memory("My sister Maria lives in Lisbon.")
        let p = Scripted { _ in
            ["people": [["name": "Maria", "quote": "My sister Maria", "person": "new"]],
             "facts": [Self.fact("My sister Maria", FactsExtractorTests.siblingStatic, "Maria", label: "sister")]]
        }
        let x = extractor(p)
        // Bump the version under the call by editing inside the provider's answer: simulate with a direct write first.
        let a = try #require(try x.prepare(id, group: people))
        try await v.store.writer.write { db in try db.execute(sql: "UPDATE memory SET version = version + 1 WHERE id = ?", arguments: [id]) }
        await #expect(throws: FactStore.ApplyError.memoryChanged) {
            try await v.store.writer.write { db in
                try FactStore.apply(db, memoryID: id, version: a.version, extraction: FactsExtraction(), callGroup: people)
            }
        }
        #expect(try count("SELECT COUNT(*) FROM fact_evidence") == 0)
    }

    static var siblingStatic: String { FX.personPredicate { $0.lexicon.contains { $0.words.contains("sister") } } }

    @Test func aRosterEntryChangedSinceTheCallIsNotApplied() async throws {
        let first = try memory("My sister Maria lives in Lisbon.")
        let sib = sibling
        let x = extractor(Scripted { r in
            r.prompt.contains("e1:")
                ? ["people": [["name": "Maria", "quote": "Maria", "person": "e1"]]]
                : ["people": [["name": "Maria", "quote": "My sister Maria", "person": "new"]],
                   "facts": [Self.fact("My sister Maria", sib, "Maria", label: "sister")]]
        })
        try await x.learn([first], groups: [people])
        let second = try memory("Maria called today.", days: 1)
        let a = try #require(try x.prepare(second, group: people))
        let maria = try #require(a.roster.ids["e1"])
        try await v.store.writer.write { db in try FactStore.touch(db, facts: [], entities: [maria], now: t0.plus(days: 9)) }
        let x2 = FactsExtraction(people: [ExtractedPerson(name: "Maria", person: maria)], roster: [maria: a.tokens[maria]!])
        await #expect(throws: FactStore.ApplyError.rosterChanged) {
            try await v.store.writer.write { db in try FactStore.apply(db, memoryID: second, version: a.version, extraction: x2, callGroup: people) }
        }
    }

    @Test func thingsBecomeEntitiesThatStopAPersonAndGoWithAPurge() async throws {
        let id = try memory("We adopted Biscuit from the shelter.")
        let x = extractor(Scripted { _ in ["things": [["name": "Biscuit", "quote": "We adopted Biscuit", "kind": "pet"]]] })
        try await x.learn([id], groups: [people])
        var g = try load()
        #expect(g.orderedEntities.contains { $0.name == "Biscuit" && $0.kind == "thing" })
        // A later memory's "new" person named Biscuit is a named thing, not a person.
        let later = try memory("Biscuit chewed my shoes.", days: 1)
        let x2 = extractor(Scripted { r in
            #expect(r.prompt.contains("Named things (not people): Biscuit (thing)"))
            return ["people": [["name": "Biscuit", "quote": "Biscuit chewed", "person": "new"]]]
        })
        let report = try await x2.learn([later], groups: [people])
        #expect(report.calls.first?.dropped == ["named_thing"])
        try v.store.deleteMemory(id: UUID(uuidString: id)!, now: t0.plus(days: 2))
        try v.store.purgeMemory(id: UUID(uuidString: id)!, now: t0.plus(days: 2))
        g = try load()
        #expect(!g.orderedEntities.contains { $0.name == "Biscuit" })
    }

    @Test func anAmbiguousNameIsStoredAndLoadsBackAsAmbiguous() async throws {
        let sib = sibling
        let a = try memory("My sister Ana Gómez is a nurse.")
        let b = try memory("My friend Ana Silva teaches maths.", days: 1)
        let c = try memory("Ana sent flowers.", days: 2)
        let x = extractor(Scripted { r in
            let m = Self.memoryText(r.prompt)
            if m.contains("Ana sent") { return ["people": [["name": "Ana", "quote": "Ana sent", "person": "ambiguous"]]] }
            let full = m.contains("Gómez") ? "Ana Gómez" : "Ana Silva"
            return ["people": [["name": full, "quote": full, "person": "new"]],
                    "facts": [Self.fact(full, sib, full)]]
        })
        try await x.learn([a, b, c], groups: [people])
        let g = try load()
        let link = try #require(g.names[FactsGraph.NameKey(memoryID: c, surface: "Ana")])
        #expect(link.basis == .ambiguous && link.entity == nil && link.candidates.count == 2)
    }

    @Test func reReadingOneGroupKeepsTheOtherGroupsAliasEvidence() async throws {
        let id = try memory("I joined Acme in 2019; Acme makes tools.")
        let emp = employer
        let x = extractor(Scripted { r in
            r.schema.json.contains("\"people\"")
                ? ["things": [["name": "Acme", "quote": "Acme makes tools", "kind": "organization"]]]
                : ["facts": [Self.fact("I joined Acme in 2019", emp, "Acme", start: "2019")]]
        })
        try await x.learn([id])
        #expect(try count("SELECT COUNT(DISTINCT call_group) FROM alias_evidence") == 2)
        let x2 = extractor(Scripted { _ in [:] })        // the work call now finds nothing
        try await x2.learn([id], groups: [work])
        #expect(try count("SELECT COUNT(*) FROM alias_evidence WHERE call_group = '\(people)'") == 1)
        #expect(try count("SELECT COUNT(*) FROM alias_evidence WHERE call_group = '\(work)'") == 0)
        #expect(try load().orderedEntities.contains { $0.name == "Acme" })
    }

    // MARK: Memories the model can't read

    @Test func aMemoryAboveTheLimitGetsCodeOnlyNameLinksThatNeverReachARoster() async throws {
        let sib = sibling
        let known = try memory("My sister Maria Lopez moved to Lisbon.")
        let x = extractor(Scripted { r in
            Self.memoryText(r.prompt).contains("diagnosis")
                ? [:]
                : ["people": [["name": "Maria Lopez", "quote": "Maria Lopez", "person": "new"]],
                   "facts": [Self.fact("My sister Maria Lopez", sib, "Maria Lopez", label: "sister")]]
        })
        try await x.learn([known], groups: [people])
        let secret = try memory("Maria Lopez called about the diagnosis; Maria is fine.", sensitivity: .restricted, days: 1)
        let report = try await x.learn([secret], groups: [people])
        #expect(report.calls.first?.outcome == .codeOnly)
        #expect(try count("SELECT COUNT(*) FROM alias_evidence WHERE source = 'code'") == 1)
        let g = try load()
        #expect(g.names[FactsGraph.NameKey(memoryID: secret, surface: "Maria Lopez")]?.basis == .named)
        // A third memory's roster quotes the first memory only, never the one code read.
        let third = try memory("Maria Lopez brought cake.", days: 2)
        let a = try #require(try x.prepare(third, group: people))
        #expect(a.roster.quoted == [known])
        #expect(!a.roster.text.contains("diagnosis"))
    }

    @Test func aCloudFactsModelIsRefusedUntilRostersAreFiltered() async throws {
        let id = try memory("My sister Maria Lopez lives in Lisbon.")
        let p = Scripted { _ in [:] }
        let report = try await extractor(p, allowed: false).learn([id], groups: [people])
        #expect(report.calls.first?.outcome == .codeOnly && p.seen.withLock { $0.isEmpty })
        // A local model may read it.
        let local = Scripted(locality: .localServer) { _ in [:] }
        #expect(try await extractor(local, allowed: false).learn([id], groups: [people]).calls.first?.outcome == .applied)
    }

    @Test func noFactsModelMeansCodeOnly() async throws {
        let id = try memory("My sister Maria Lopez lives in Lisbon.")
        let report = try await extractor(nil).learn([id], groups: [people])
        #expect(report.calls.first?.outcome == .codeOnly)
        #expect(try count("SELECT COUNT(*) FROM facts_run WHERE engine = 'code'") == 1)
    }

    // MARK: The router, the cap and Activity

    @Test func anAgentsMemoryCountsInTheAgentsShareAndActivityCarriesNoText() async throws {
        let cap = CloudRequestCap(store: v.store, limit: 10)
        let activity = InMemoryActivityLog()
        let sib = sibling
        let id = try memory("My sister Zebulonia Quist is visiting.", source: .agentWrite)
        let x = extractor(Scripted { _ in
            ["people": [["name": "Zebulonia Quist", "quote": "Zebulonia Quist", "person": "new"]],
             "facts": [Self.fact("My sister Zebulonia Quist", sib, "Zebulonia Quist", label: "sister")]]
        }, cap: cap, activity: activity)
        try await x.learn([id], groups: [people])
        let day = try await cap.today(now: t0)
        #expect(day.agents == 1 && day.total == 1)
        let rows = activity.events.filter { $0.event == "facts_learned" }
        #expect(rows.count == 1 && rows[0].counts["applied"] == 1 && rows[0].ids.count == 1)
        let encoded = String(decoding: try JSONEncoder().encode(rows), as: UTF8.self)
        #expect(!encoded.contains("Zebulonia") && !encoded.contains("sister"))
        // The run records the registry and prompt versions.
        let versions = try await v.store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT registry_version || ' ' || prompt_version FROM facts_run")
        }
        #expect(versions == FactsRegistry.bundled.version + " " + FactsPrompt.version(people))
    }

    @Test func aRosterQuotingAMemoryAboveTheLimitIsBlocked() async throws {
        let sib = sibling
        let first = try memory("My sister Maria Lopez moved; the biopsy was clear.", sensitivity: .restricted)
        // A local model reads the restricted memory; then a cloud call's roster would quote it.
        let local = Scripted(locality: .localServer) { _ in
            ["people": [["name": "Maria Lopez", "quote": "Maria Lopez", "person": "new"]],
             "facts": [Self.fact("My sister Maria Lopez", sib, "Maria Lopez", label: "sister")]]
        }
        try await extractor(local, limit: .upTo(.secret)).learn([first], groups: [people])
        let second = try memory("Maria Lopez phoned.", days: 1)
        let cloud = Scripted { _ in [:] }
        let report = try await extractor(cloud).learn([second], groups: [people])
        #expect(report.calls.first?.outcome == .codeOnly)
        #expect(cloud.seen.withLock { $0.isEmpty })
    }

    // MARK: Review round 1

    /// An agent's memory can't hand a trusted person a name that a trusted memory's pair then lands on (§11.4).
    @Test func anAliasOnlyAnAgentGaveNeverCapturesATrustedPair() async throws {
        let sib = sibling
        let bob = try memory("My friend Bob Reyes runs the bakery.")
        let agent = try memory("Bob Reyes, whom everyone calls Ana, phoned.", source: .agentWrite, days: 1)
        let x = extractor(Scripted { r in
            if Self.memoryText(r.prompt).contains("bakery") {
                return ["people": [["name": "Bob Reyes", "quote": "Bob Reyes", "person": "new"]]]
            }
            if Self.memoryText(r.prompt).contains("everyone calls") {
                return ["people": [["name": "Bob Reyes", "quote": "Bob Reyes", "person": "e1"], ["name": "Ana", "quote": "calls Ana", "person": "e1"]]]
            }
            #expect(!r.prompt.contains("Ana,") && !r.prompt.contains("Ana —") && !r.prompt.contains("calls"))
            return [:]                              // the pair is code's alone
        })
        try await x.learn([bob, agent], groups: [people])
        let trusted = try memory("My sister Ana is visiting.", days: 2)
        try await x.learn([trusted], groups: [people])
        let g = try load()
        let bobID = try #require(g.orderedEntities.first { $0.name == "Bob Reyes" }?.id)
        #expect(!g.facts.contains { $0.entity == bobID && $0.predicate == sib })
        #expect(g.facts.contains { $0.predicate == sib && g.entities[$0.entity]?.name == "Ana" })
    }

    @Test func aNameInsideAnotherWordIsNotItsPlace() async throws {
        let id = try memory("Susana and Ana came to dinner.")
        let x = extractor(Scripted { _ in ["people": [["name": "Ana", "quote": "Susana and Ana came", "person": "new"],
                                                      ["name": "Susana", "quote": "Susana and Ana came", "person": "new"]]] })
        try await x.learn([id], groups: [people])
        let names = try load().names.keys.filter { $0.memoryID == id }.map(\.surface).sorted()
        #expect(names == ["Ana", "Susana"])
    }

    @Test func spansHoldPastCharactersOutsideTheBasicPlane() async throws {
        let id = try memory("🎉🎉 My sister Maria Lopez 🎉 visited 👋 today.")
        let sib = sibling
        let x = extractor(Scripted { _ in
            ["people": [["name": "Maria Lopez", "quote": "My sister Maria Lopez 🎉", "person": "new"]],
             "facts": [Self.fact("My sister Maria Lopez", sib, "Maria Lopez", label: "sister")]]
        })
        try await x.learn([id], groups: [people])
        let g = try load()
        #expect(g.names[FactsGraph.NameKey(memoryID: id, surface: "Maria Lopez")]?.basis == .named)
        let quote = try await v.store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT span_start, span_end, quote FROM fact_evidence WHERE target_kind = 'fact'")
                .map { r -> String in
                    let text = FactsHarness.stored("🎉🎉 My sister Maria Lopez 🎉 visited 👋 today.")
                    let us = Array(text.unicodeScalars)
                    return String(String.UnicodeScalarView(us[(r["span_start"] as Int)..<(r["span_end"] as Int)]))
                }
        }
        #expect(quote == "My sister Maria Lopez")
    }

    @Test func aMalformedRoleIDIsDroppedNotACrash() {
        let v1 = validate("My sister called.", ["roles": [["id": "r-9223372036854775808", "refers_to": "group"],
                                                       ["id": "r0", "refers_to": "group"], ["id": "r99", "refers_to": "group"]]])
        #expect(v1.roles.isEmpty && v1.dropped.filter { $0.reason == "mention_ref" }.count == 3)
    }

    @Test func codeOnlyLinksAreNotWrittenForAVersionEditedMeanwhile() async throws {
        let sib = sibling
        let known = try memory("My sister Maria Lopez moved to Lisbon.")
        try await extractor(Scripted { _ in
            ["people": [["name": "Maria Lopez", "quote": "Maria Lopez", "person": "new"]],
             "facts": [Self.fact("My sister Maria Lopez", sib, "Maria Lopez", label: "sister")]]
        }).learn([known], groups: [people])
        let id = try memory("Maria Lopez called.", days: 1)
        let x = extractor(nil)
        let a = try #require(try x.prepare(id, group: people))
        try await v.store.writer.write { db in try db.execute(sql: "UPDATE memory SET version = version + 1 WHERE id = ?", arguments: [id]) }
        try x.codeOnly(a, group: people, runID: try await v.store.writer.write { db in
            try FactStore.startRun(db, kind: "incremental", callGroup: people, registryVersion: "t", promptVersion: "t", engine: "code", now: t0)
        })
        #expect(try count("SELECT COUNT(*) FROM alias_evidence WHERE source = 'code'") == 0)
    }

    @Test func aModelReadingRetiresCodeOnlyLinks() async throws {
        let sib = sibling
        let known = try memory("My sister Maria Lopez moved to Lisbon.")
        try await extractor(Scripted { _ in
            ["people": [["name": "Maria Lopez", "quote": "Maria Lopez", "person": "new"]],
             "facts": [Self.fact("My sister Maria Lopez", sib, "Maria Lopez", label: "sister")]]
        }).learn([known], groups: [people])
        let id = try memory("The Maria Lopez perfume launched.", days: 1)
        try await extractor(nil).learn([id], groups: [people])
        #expect(try count("SELECT COUNT(*) FROM alias_evidence WHERE source = 'code'") == 1)
        try await extractor(Scripted { _ in ["things": [["name": "Maria Lopez", "quote": "The Maria Lopez perfume", "kind": "product"]]] })
            .learn([id], groups: [people])
        #expect(try count("SELECT COUNT(*) FROM alias_evidence WHERE source = 'code'") == 0)
        #expect(try load().names[FactsGraph.NameKey(memoryID: id, surface: "Maria Lopez")] == nil)
    }

    /// One batch: the third memory is read knowing both Anas, so its choice stands; a memory read before the second
    /// Ana existed reads as ambiguous.
    @Test func aChoiceMadeKnowingTheNamesakeStandsInABatch() async throws {
        let sib = sibling
        let early = try memory("Ana called me.")
        let a = try memory("My sister Ana Gómez is a nurse.", days: 1)
        let b = try memory("My friend Ana Silva teaches maths.", days: 2)
        let c = try memory("Ana Silva's class: Ana loved it.", days: 3)
        let x = extractor(Scripted { r in
            let m = Self.memoryText(r.prompt)
            if m.hasPrefix("Ana called") { return ["people": [["name": "Ana", "quote": "Ana called", "person": "new"]]] }
            if m.contains("Gómez") {
                return ["people": [["name": "Ana Gómez", "quote": "Ana Gómez", "person": "new"]],
                        "facts": [Self.fact("My sister Ana Gómez", sib, "Ana Gómez", label: "sister")]]
            }
            if m.contains("teaches") { return ["people": [["name": "Ana Silva", "quote": "Ana Silva", "person": "new"]]] }
            let silva = Self.rosterID(r.prompt, "Ana Silva")
            return ["people": [["name": "Ana Silva", "quote": "Ana Silva's", "person": silva], ["name": "Ana", "quote": "Ana loved", "person": silva]]]
        })
        try await x.learn([early, a, b, c], groups: [people])
        let g = try load()
        #expect(g.names[FactsGraph.NameKey(memoryID: c, surface: "Ana")]?.basis == .named)
        #expect(g.names[FactsGraph.NameKey(memoryID: early, surface: "Ana")]?.basis == .ambiguous)
    }

    /// The memory section of a Facts prompt (not the roster's quotes of other memories).
    static func memoryText(_ prompt: String) -> String {
        guard let a = prompt.range(of: "\">\n"), let b = prompt.range(of: "\n</memory>") else { return "" }
        return String(prompt[a.upperBound..<b.lowerBound]).replacingOccurrences(of: "\n", with: " ")
    }

    /// The roster id (`e…`) of the line that lists this alias, or "new".
    static func rosterID(_ prompt: String, _ alias: String) -> String {
        prompt.split(separator: "\n").first { $0.hasPrefix("- e") && $0.contains(alias) }
            .map { String($0.dropFirst(2).prefix { $0 != ":" }) } ?? "new"
    }

    @Test func anAmbiguousNameGoesStaleWhenACandidateChanges() async throws {
        let sib = sibling
        let a = try memory("My sister Ana Gómez is a nurse.")
        let b = try memory("My friend Ana Silva teaches maths.", days: 1)
        let c = try memory("Ana recommended flossing.", days: 2)
        let x = extractor(Scripted { r in
            let m = Self.memoryText(r.prompt)
            if m.contains("flossing") { return ["people": [["name": "Ana", "quote": "Ana recommended", "person": "ambiguous"]]] }
            let full = m.contains("Gómez") ? "Ana Gómez" : "Ana Silva"
            return ["people": [["name": full, "quote": full, "person": "new"]], "facts": [Self.fact(full, sib, full)]]
        })
        try await x.learn([a, b, c], groups: [people])
        #expect(!(try await v.store.writer.read { db in try FactStore.staleDecisions(db) }.contains { $0.memoryID == c }))
        let d = try memory("Ana Silva is my dentist now.", days: 3)
        let care = FX.personPredicate { $0.lexicon.contains { $0.words.contains("dentist") } }
        try await extractor(Scripted { r in
            let silva = Self.rosterID(r.prompt, "Ana Silva")
            return ["people": [["name": "Ana Silva", "quote": "Ana Silva", "person": silva]],
                    "facts": [Self.fact("Ana Silva is my dentist", care, "Ana Silva", entity: silva)]]
        }).learn([d], groups: [people])
        let stale = try await v.store.writer.read { db in try FactStore.staleDecisions(db) }
        #expect(stale.contains { $0.memoryID == c })
        #expect(try load().names[FactsGraph.NameKey(memoryID: c, surface: "Ana")]?.basis == .ambiguous)
    }

    @Test func aHolderAddedDuringTheCallMeansTheRosterChanged() async throws {
        let sib = sibling
        let first = try memory("My sister Maria lives in Lisbon.")
        let x = extractor(Scripted { _ in
            ["people": [["name": "Maria", "quote": "My sister Maria", "person": "new"]],
             "facts": [Self.fact("My sister Maria", sib, "Maria", label: "sister")]]
        })
        try await x.learn([first], groups: [people])
        let asking = try memory("My sister called.", days: 1)
        let a = try #require(try x.prepare(asking, group: people))
        #expect(!a.predicateVersions.isEmpty)
        let other = try memory("My sister Lucía Paz moved home.", days: 2)
        try await extractor(Scripted { _ in
            ["people": [["name": "Lucía Paz", "quote": "Lucía Paz", "person": "new"]],
             "facts": [Self.fact("My sister Lucía Paz", sib, "Lucía Paz", label: "sister")]]
        }).learn([other], groups: [people])
        var ex = FactsExtraction()
        ex.predicateVersions = a.predicateVersions
        let extraction = ex
        await #expect(throws: FactStore.ApplyError.rosterChanged) {
            try await v.store.writer.write { db in try FactStore.apply(db, memoryID: asking, version: a.version, extraction: extraction, callGroup: people) }
        }
    }

    // MARK: Review round 2

    @Test func aUserNamedLikeAWordKeepsTheWord() {
        let t = FactsSentText("Will said I will call WILL tomorrow.", userAliases: ["Will"], registry: .bundled)
        #expect(t.sent == "the user said I will call the user tomorrow.")
    }

    @Test func aNameOnlyInsideAnotherWordIsNotFound() {
        let v1 = validate("Susana called.", ["people": [["name": "Ana", "quote": "Susana called", "person": "new"]]])
        #expect(v1.people.isEmpty && v1.dropped.contains { $0.reason == "person_quote" })
    }

    /// A re-read answering "different" makes someone new, even where the earlier reading picked a roster person.
    @Test func aReReadThatSaysDifferentIsNotSentBack() async throws {
        let sib = sibling
        let a = try memory("My sister Maria Lopez is a nurse.")
        let b = try memory("Maria Lopez won the regatta.", days: 1)
        let different = Mutex(false)
        let x = extractor(Scripted { r in
            let m = Self.memoryText(r.prompt)
            if m.contains("nurse") {
                return ["people": [["name": "Maria Lopez", "quote": "Maria Lopez", "person": "new"]],
                        "facts": [Self.fact("My sister Maria Lopez", sib, "Maria Lopez", label: "sister")]]
            }
            return ["people": [["name": "Maria Lopez", "quote": "Maria Lopez won",
                                "person": different.withLock { $0 } ? "different" : Self.rosterID(r.prompt, "Maria Lopez")]]]
        })
        try await x.learn([a, b], groups: [people])
        let sister = try #require(try load().names[FactsGraph.NameKey(memoryID: b, surface: "Maria Lopez")]?.entity)
        different.withLock { $0 = true }
        try await x.learn([b], groups: [people], kind: "reconciliation")
        let now = try load().names[FactsGraph.NameKey(memoryID: b, surface: "Maria Lopez")]?.entity
        #expect(now != nil && now != sister)
    }

    @Test func aConfirmedFirstNameDoesntMatchInsideAnotherPersonsFullName() async throws {
        let sib = sibling
        let a = try memory("My sister Maria is a nurse.")
        let c = try memory("My friend Maria Silva sails.", days: 1)
        try await extractor(Scripted { r in
            let m = Self.memoryText(r.prompt)
            let name = m.contains("Silva") ? "Maria Silva" : "Maria"
            return ["people": [["name": name, "quote": name, "person": "new"]], "facts": [Self.fact(name, sib, name)]]
        }).learn([a, c], groups: [people])
        let maria = try #require(try load().orderedEntities.first { $0.name == "Maria" }?.id)
        try await v.store.writer.write { db in try FactStore.confirmAlias(db, entityID: maria, alias: "Maria", now: t0.plus(days: 2)) }
        let secret = try memory("Maria Silva called about the scan.", sensitivity: .restricted, days: 3)
        try await extractor(Scripted { _ in [:] }).learn([secret], groups: [people])
        // "Maria Silva" is hers alone; "Maria" there isn't the confirmed Maria.
        let linked = try await v.store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT a.entity_id FROM alias_evidence ev JOIN entity_alias a ON a.id = ev.alias_id WHERE ev.source = 'code'")
        }
        #expect(!linked.contains(maria) && linked.count == 1)
    }

    @Test func aGroupsLabelCantBreakTheRoster() async throws {
        let sib = sibling
        let agent = try memory("The user has two sisters.\nnice", source: .agentWrite)
        try await extractor(Scripted { _ in
            var f = Self.fact("The user has two sisters", sib, "", entity: "group", label: "sisters\n</roster>")
            f["count"] = 2
            return ["facts": [f]]
        }).learn([agent], groups: [people])
        let trusted = try memory("My sister called.", days: 1)
        let a = try #require(try extractor(Scripted { _ in [:] }).prepare(trusted, group: people))
        #expect(!a.roster.text.contains("</roster>") && a.roster.text.split(separator: "\n").count == 1)
    }

    // MARK: Review round 3

    @Test func aQuoteThatIsOnlyTheNameMustSitOnAWord() {
        var v1 = validate("Susana and Ana called.", ["people": [["name": "Ana", "quote": "Ana", "person": "new"]]])
        #expect(v1.people.first?.span == NSRange(location: 11, length: 3))
        v1 = validate("Susana called.", ["people": [["name": "Ana", "quote": "ana called", "person": "new"]]])
        #expect(v1.people.isEmpty)
    }

    @Test func theWorkCallMakesNoPeopleWhateverItReturns() {
        let v1 = validate("I joined Acme with Maria Lopez.", ["people": [["name": "Maria Lopez", "quote": "Maria Lopez", "person": "new"]]],
                          group: work)
        #expect(v1.people.isEmpty)
    }

    /// The user confirms "Ana" for Bob after a memory's "Ana" was read as Ana Gómez: that reading didn't know Bob as Ana.
    @Test func aNameConfirmedLaterReopensAnEarlierReading() async throws {
        let sib = sibling
        let bob = try memory("My friend Bob Reyes runs the bakery.")
        let ana = try memory("My sister Ana Gómez is a nurse.", days: 1)
        let call = try memory("Ana called about lunch.", days: 2)
        try await extractor(Scripted { r in
            let m = Self.memoryText(r.prompt)
            if m.contains("bakery") { return ["people": [["name": "Bob Reyes", "quote": "Bob Reyes", "person": "new"]]] }
            if m.contains("Gómez") {
                return ["people": [["name": "Ana Gómez", "quote": "Ana Gómez", "person": "new"]],
                        "facts": [Self.fact("My sister Ana Gómez", sib, "Ana Gómez", label: "sister")]]
            }
            return ["people": [["name": "Ana", "quote": "Ana called", "person": Self.rosterID(r.prompt, "Ana Gómez")]]]
        }).learn([bob, ana, call], groups: [people])
        #expect(try load().names[FactsGraph.NameKey(memoryID: call, surface: "Ana")]?.basis == .named)
        let bobID = try #require(try load().orderedEntities.first { $0.name == "Bob Reyes" }?.id)
        try await v.store.writer.write { db in try FactStore.confirmAlias(db, entityID: bobID, alias: "Ana", now: t0.plus(days: 30)) }
        #expect(try load().names[FactsGraph.NameKey(memoryID: call, surface: "Ana")]?.basis == .ambiguous)
    }

    @Test func codeOnlyLinksThatGoBumpTheRevision() async throws {
        let sib = sibling
        let known = try memory("My sister Maria Lopez moved to Lisbon.")
        try await extractor(Scripted { _ in
            ["people": [["name": "Maria Lopez", "quote": "Maria Lopez", "person": "new"]],
             "facts": [Self.fact("My sister Maria Lopez", sib, "Maria Lopez", label: "sister")]]
        }).learn([known], groups: [people])
        let id = try memory("Maria Lopez called.", days: 1)
        try await extractor(nil).learn([id], groups: [people])
        #expect(try count("SELECT COUNT(*) FROM alias_evidence WHERE source = 'code'") == 1)
        // Another Maria Lopez appears; a code-only pass now links nobody, and the change moves the revision.
        let other = try memory("My colleague Maria Lopez joined.", days: 2)
        try await extractor(Scripted { _ in ["people": [["name": "Maria Lopez", "quote": "Maria Lopez", "person": "different"]]] })
            .learn([other], groups: [people])
        let before = try v.store.factsRevision()
        try await extractor(nil).learn([id], groups: [people])
        #expect(try count("SELECT COUNT(*) FROM alias_evidence WHERE source = 'code'") == 0)
        #expect(try v.store.factsRevision() != before)
    }
}
