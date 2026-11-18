import Foundation
import FunesProtocol
import GRDB
import Synchronization
import Testing
@testable import FunesCore

/// Phase 13a.2's privacy step (memory processing §11.3, §11.9): a cloud Facts call's roster is built from what's
/// sendable under the cloud limit only, each line a typed item; reconciliation compares what readings knew on the same
/// graph; the user's names become "the user" while a namesake keeps their name. Payload tests put sentinel strings at
/// every sensitivity and look for them in everything a cloud provider receives. No live calls.
@Suite(.serialized) struct FactsPrivacyTests {
    typealias Scripted = FactsExtractorTests.Scripted
    let v: TestVault
    let people: String
    let user = ["Dani Ortega", "Dani"]

    init() throws {
        v = try TestVault()
        let reg = FactsRegistry.bundled
        people = reg.callGroups.keys.sorted().first { FactsPrompt.hasPeople($0, reg) }!
    }

    var sibling: String { FX.personPredicate { $0.lexicon.contains { $0.words.contains("sister") } } }
    var boss: String { FX.personExclusive }

    func extractor(_ provider: (any GenerationProvider)?, limit: CloudLimit = .upTo(.low)) -> FactsExtractor {
        let clock = FactsHarness.Clock()
        var x = FactsExtractor(store: v.store, router: ModelRouter(classifier: nil, onDevice: nil, cloudLimit: limit, factsModel: provider),
                               activity: InMemoryActivityLog(), userAliases: user)
        x.clock = { clock.now() }
        return x
    }

    /// A local model: reads everything, with the whole roster.
    func local(_ answer: @escaping @Sendable (StructuredRequest<FactsJSON>) -> [String: Any]) -> FactsExtractor {
        extractor(Scripted(locality: .localServer, answer), limit: .upTo(.secret))
    }

    func memory(_ text: String, _ sensitivity: Sensitivity = .low, days: Double = 0) throws -> String {
        let (title, body) = FactsHarness.split(text)
        return try v.memory(title, body, sensitivity: sensitivity, now: t0.plus(days: days)).id.db
    }

    func load(_ limit: CloudLimit? = nil) throws -> FactsGraph {
        try v.store.writer.read { db in try FactStore.load(db, userAliases: user, sendable: limit).graph }
    }

    func entity(_ g: FactsGraph, _ alias: String) -> FactsEntity? { g.entities.values.first { $0.aliases.contains(alias) } }

    static func person(_ name: String, _ quote: String? = nil, _ ref: String = "new") -> [String: Any] {
        ["name": name, "quote": quote ?? name, "person": ref]
    }

    static func sent(_ p: Scripted) -> String { p.seen.withLock { $0.map { $0.instructions + "\n" + $0.prompt }.joined(separator: "\n") } }

    // MARK: Payload tests

    @Test func noSentinelAboveTheLimitReachesACloudCallAndThoseWithinItDo() async throws {
        let sib = sibling
        let levels = Sensitivity.allCases
        let names = ["Odalric Fenwick", "Brisa Malquist", "Tamsin Orrell", "Yusra Delacombe", "Pietro Halvane", "Corin Ashgrove"]
        let words = ["Saffronel", "Quillbrook", "Marrowind", "Tesselate", "Vantorium", "Gildersee"]
        let typed = ["Ulmer Kask", "Ione Brack", "Rhys Tolland", "Wenna Strode", "Galen Pyke", "Nell Crowther"]
        let labels = ["brindlewick", "corvantine", "dellamore", "esquivane", "farrowly", "galthorpe"]
        let groupLabels = ["hollinshed", "irongate", "jessamine", "kittering", "lowenfeld", "marlowe"]
        let things = ["Nimbrel Works", "Oskarvale Mill", "Pellinore Yard", "Quistgard Inn", "Rondeleux Farm", "Sallowmere Dock"]
        var mems: [String: Sensitivity] = [:]
        for (i, level) in levels.enumerated() {
            mems[try memory("My sister \(names[i]) sent the \(words[i]) parcel; she is my \(labels[i]) sister. "
                            + "My \(groupLabels[i]) cousins came too, from \(things[i]).", level, days: Double(i))] = level
        }
        // A person a public memory introduced, with a fact only a secret memory states.
        let lenaFirst = try memory("Lena Ostrova came by with cake.", .public, days: 10)
        mems[lenaFirst] = .public
        let lenaSecret = try memory("Lena Ostrova is my sister, says the Hollowmere file.", .secret, days: 11)
        mems[lenaSecret] = .secret
        let reader = local { r in
            let text = FactsExtractorTests.memoryText(r.prompt)
            if let i = names.firstIndex(where: { text.contains($0) }) {
                return ["people": [Self.person(names[i])],
                        "facts": [FactsExtractorTests.fact("she is my \(labels[i]) sister", sib, names[i], label: labels[i]),
                                  FactsExtractorTests.fact("My \(groupLabels[i]) cousins", sib, "", entity: "group", label: groupLabels[i])],
                        "things": [["name": things[i], "quote": "from \(things[i])", "kind": "place"]]]
            }
            if text.contains("Hollowmere") {
                return ["people": [Self.person("Lena Ostrova", nil, FactsExtractorTests.rosterID(r.prompt, "Lena Ostrova"))],
                        "facts": [FactsExtractorTests.fact("Lena Ostrova is my sister", sib, "Lena Ostrova", label: "sister")]]
            }
            if text.contains("Lena Ostrova") { return ["people": [Self.person("Lena Ostrova")]] }
            return [:]
        }
        try await reader.learn(Array(mems.keys).sorted { mems[$0]! < mems[$1]! }, groups: [people])
        try await reader.learn([lenaFirst], groups: [people])
        try await reader.learn([lenaSecret], groups: [people])
        // Manual entries at each sensitivity: the user's own pick.
        for (i, level) in levels.enumerated() {
            try await v.store.writer.write { db in
                _ = try FactStore.addManualFact(db, predicate: sib, name: typed[i], sensitivity: level.rawValue, now: t0)
            }
        }
        let whole = try load()
        let lenaID = entity(whole, "Lena Ostrova")?.id
        #expect(whole.facts.contains { $0.predicate == sib && $0.entity == lenaID })

        let target = try memory("Dani's sister phoned about the parcel.", .public, days: 20)
        for limit in levels {
            let cloud = Scripted { _ in [:] }
            let x = extractor(cloud, limit: .upTo(limit))
            let report = try await x.learn([target], groups: [people])
            #expect(report.calls.first?.outcome == .applied, "a call at \(limit)")
            let sent = Self.sent(cloud)
            for (i, level) in levels.enumerated() {
                let within = level <= limit
                #expect(sent.contains(names[i]) == within, "\(names[i]) at \(level), limit \(limit)")
                #expect(sent.contains(words[i]) == within, "\(words[i]) at \(level), limit \(limit)")
                #expect(sent.contains(typed[i]) == within, "\(typed[i]) at \(level), limit \(limit)")
                #expect(sent.contains(labels[i]) == within, "\(labels[i]) at \(level), limit \(limit)")
                #expect(sent.contains(groupLabels[i]) == within, "\(groupLabels[i]) at \(level), limit \(limit)")
                #expect(sent.contains(things[i]) == within, "\(things[i]) at \(level), limit \(limit)")
            }
            // Lena is listed, but her sister fact rests on the secret memory.
            let lena = sent.split(separator: "\n").first { $0.hasPrefix("- e") && $0.contains("Lena Ostrova") }.map(String.init) ?? ""
            #expect(!lena.isEmpty)
            #expect(lena.contains(sib) == (limit == .secret), "Lena's fact at limit \(limit)")
            #expect(sent.contains("Hollowmere") == (limit == .secret))
            #expect(!sent.contains("Dani"))
            // Which memories are selected: the roster quotes and lists only what's within the limit.
            let a = try #require(try x.prepare(target, group: people))
            #expect(a.roster.quoted.allSatisfy { (mems[$0] ?? .secret) <= limit })
            #expect(a.lineSensitivity.count == a.roster.lines.count)
            #expect(a.lineSensitivity.allSatisfy { $0.map { $0 <= limit } ?? false })
        }
        // Never: no request at all.
        let never = Scripted { _ in [:] }
        #expect(try await extractor(never, limit: .never).learn([target], groups: [people]).calls.first?.outcome == .codeOnly)
        #expect(never.seen.withLock { $0.isEmpty })
    }

    @Test func aMemoryAboveTheLimitMakesNoRequest() async throws {
        let id = try memory("My sister Maria Lopez moved.", .restricted)
        let cloud = Scripted { _ in [:] }
        #expect(try await extractor(cloud).learn([id], groups: [people]).calls.first?.outcome == .codeOnly)
        #expect(cloud.seen.withLock { $0.isEmpty })
    }

    @Test func aRosterLineOfUnknownSensitivityIsRefusedByTheRouter() async throws {
        // The typed items are what `ModelRouter.send` checks: an unknown or higher level blocks the call.
        let router = ModelRouter(classifier: nil, onDevice: nil, cloudLimit: .upTo(.low), factsModel: Scripted { _ in [:] })
        let request = StructuredRequest<FactsJSON>(instructions: "i", prompt: "p", schema: FactsPrompt.schema(people))
        for line in [ModelItem("- e1: Somebody", sensitivity: nil), ModelItem("- e1: Somebody", sensitivity: .sensitive)] {
            await #expect(throws: ProviderError.blocked) {
                _ = try await router.facts(request, items: [ModelItem("text", sensitivity: .low), line], requester: .user, now: t0)
            }
        }
    }

    // MARK: The sendable graph

    @Test func aPersonARestrictedReadingIntroducedIsWithheldWhole() async throws {
        let first = try memory("Ana Ruiz is my doctor.", .restricted)
        let later = try memory("Ana phoned about the results.", .low, days: 1)
        let x = local { r in
            let text = FactsExtractorTests.memoryText(r.prompt)
            return text.contains("Ana Ruiz") ? ["people": [Self.person("Ana Ruiz")]]
                : ["people": [Self.person("Ana", "Ana phoned", FactsExtractorTests.rosterID(r.prompt, "Ana Ruiz"))]]
        }
        try await x.learn([first], groups: [people])
        try await x.learn([later], groups: [people])
        #expect(entity(try load(), "Ana")?.aliases == ["Ana", "Ana Ruiz"])
        // "Ana" alone is from a sendable memory, but it was joined to her only through the restricted one.
        #expect(entity(try load(.upTo(.low)), "Ana") == nil)
        #expect(entity(try load(.upTo(.restricted)), "Ana") != nil)
    }

    @Test func codeOnlyLinksInARestrictedMemoryWithholdNoOne() async throws {
        let sib = sibling
        let first = try memory("My sister Maria Lopez moved to Lisbon.")
        try await local { _ in
            ["people": [Self.person("Maria Lopez")], "facts": [FactsExtractorTests.fact("My sister Maria Lopez", sib, "Maria Lopez", label: "sister")]]
        }.learn([first], groups: [people])
        let secret = try memory("Maria Lopez called about the scan.", .restricted, days: 1)
        let cloud = Scripted { _ in [:] }
        #expect(try await extractor(cloud).learn([secret], groups: [people]).calls.first?.outcome == .codeOnly)
        #expect(try v.count("SELECT COUNT(*) FROM alias_evidence WHERE source = 'code'") == 1)
        let g = try load(.upTo(.low))
        let maria = try #require(entity(g, "Maria Lopez"))
        #expect(g.facts.contains { $0.entity == maria.id && $0.predicate == sib })
        #expect(g.memories[secret] == nil)
    }

    @Test func aManualEntryUsesTheSensitivityPickedAndAConfirmedAliasNeedsSendableEvidence() async throws {
        let sib = sibling
        try await v.store.writer.write { db in
            _ = try FactStore.addManualFact(db, predicate: sib, name: "Quillon Darby", sensitivity: Sensitivity.restricted.rawValue, now: t0)
        }
        #expect(entity(try load(.upTo(.low)), "Quillon Darby") == nil)
        #expect(entity(try load(.upTo(.restricted)), "Quillon Darby") != nil)

        let id = try memory("Maria Lopez brought cake.")
        try await local { _ in ["people": [Self.person("Maria Lopez")]] }.learn([id], groups: [people])
        let maria = try #require(entity(try load(), "Maria Lopez"))
        try await v.store.writer.write { db in try FactStore.confirmAlias(db, entityID: maria.id, alias: "Mimi", now: t0) }
        let whole = try load()
        #expect(entity(whole, "Maria Lopez").map { $0.aliases.contains("Mimi") } == true)
        let sendable = try load(.upTo(.secret))
        #expect(entity(sendable, "Maria Lopez").map { !$0.aliases.contains("Mimi") } == true)
    }

    @Test func aDecisionAndALinkThatRestOnAWithheldPersonAreWithheld() async throws {
        let b = boss, word = FX.word(boss)
        let secret = try memory("Hexley Brandt is my \(word) now.", .secret)
        let other = try memory("Karim Rook is my \(word) at the lab.", .low, days: 1)
        let x = local { r in
            let text = FactsExtractorTests.memoryText(r.prompt)
            for n in ["Hexley Brandt", "Karim Rook"] where text.contains(n) {
                return ["people": [Self.person(n)], "facts": [FactsExtractorTests.fact("\(n) is my \(word)", b, n)]]
            }
            // "My boss praised my report": decided as Karim, knowing about Hexley.
            let karim = FactsExtractorTests.rosterID(r.prompt, "Karim Rook")
            return ["roles": [["id": "r1", "refers_to": karim]],
                    "facts": [FactsExtractorTests.fact("My \(word) praised my report", b, "Karim Rook", entity: karim)]]
        }
        try await x.learn([secret, other], groups: [people])
        let praised = try memory("My \(word) praised my report.", .low, days: 2)
        try await x.learn([praised], groups: [people])
        let full = try load()
        #expect(full.decisions.keys.contains { $0.memoryID == praised })
        let g = try load(.upTo(.low))
        #expect(entity(g, "Hexley Brandt") == nil && entity(g, "Karim Rook") != nil)
        #expect(!g.decisions.keys.contains { $0.memoryID == praised })
        // The statement linked through the roster rests on every holder the call knew: dropped; Karim's own stays.
        let karim = try #require(entity(g, "Karim Rook"))
        #expect(full.facts.first { $0.entity == karim.id && $0.predicate == b }?.assertions.contains { $0.memoryID == praised } == true)
        let shown = try #require(g.facts.first { $0.entity == karim.id && $0.predicate == b })
        #expect(shown.assertions.map(\.memoryID) == [other])
    }

    @Test func aNameLinkRestingOnAWithheldNamesakeIsWithheld() async throws {
        let secret = try memory("Ana Ruiz runs the clinic.", .restricted)
        let bell = try memory("Ana Bell moved next door.", .low, days: 1)
        let phoned = try memory("Ana phoned last night.", .low, days: 2)
        let x = local { r in
            let text = FactsExtractorTests.memoryText(r.prompt)
            for n in ["Ana Ruiz", "Ana Bell"] where text.contains(n) { return ["people": [Self.person(n)]] }
            return ["people": [Self.person("Ana", "Ana phoned", FactsExtractorTests.rosterID(r.prompt, "Ana Bell"))]]
        }
        try await x.learn([secret, bell, phoned], groups: [people])
        #expect(try load().names[FactsGraph.NameKey(memoryID: phoned, surface: "Ana")]?.entity != nil)
        let g = try load(.upTo(.low))
        #expect(entity(g, "Ana Bell") != nil)
        #expect(g.names[FactsGraph.NameKey(memoryID: phoned, surface: "Ana")] == nil)
    }

    @Test func aGroupNeedsACountOrDecisionFromASendableMemory() async throws {
        let sib = sibling
        let id = try memory("My three sisters are coming at Easter.", .restricted)
        try await local { _ in
            var count = FactsExtractorTests.fact("My three sisters", sib, "", entity: "group", label: "sister")
            count["count"] = 3
            return ["facts": [count]]
        }.learn([id], groups: [people])
        #expect(try load().entities.values.contains { $0.group != nil && $0.name == nil })
        #expect(!(try load(.upTo(.low))).entities.values.contains { $0.group != nil && $0.name == nil })
    }

    @Test func aGroupWithoutACountGoesWithItsMemory() async throws {
        let sib = sibling
        func groups(_ g: FactsGraph) -> Int { g.entities.values.filter { $0.group != nil && $0.name == nil }.count }
        let id = try memory("My sisters are coming at Easter.", .low)
        try await local { _ in ["facts": [FactsExtractorTests.fact("My sisters", sib, "", entity: "group", label: "sister")]] }
            .learn([id], groups: [people])
        // Recorded as evidence, so a cloud roster can show it, and a purge takes it.
        let (w1, s1) = (groups(try load()), groups(try load(.upTo(.low))))
        #expect(w1 == 1 && s1 == 1)
        let restricted = try memory("My cousins are visiting the clinic.", .restricted, days: 1)
        try await local { _ in ["facts": [FactsExtractorTests.fact("My cousins", sib, "", entity: "group", label: "cousin")]] }
            .learn([restricted], groups: [people])
        let (w2, s2) = (groups(try load()), groups(try load(.upTo(.low))))
        #expect(w2 == 2 && s2 == 1)
        try await v.store.writer.write { db in
            try db.execute(sql: "DELETE FROM memory WHERE id = ?", arguments: [restricted])
            try FactStore.collectGarbage(db, now: t0)
        }
        let w3 = groups(try load())
        #expect(w3 == 1)
    }

    // MARK: Answers about what the call couldn't see

    @Test func aCloudAnswerIsntDecidedAboutPeopleItCouldntSee() async throws {
        let b = boss, word = FX.word(boss)
        let secret = try memory("Hexley Brandt is my \(word).", .secret)
        try await local { _ in
            ["people": [Self.person("Hexley Brandt")], "facts": [FactsExtractorTests.fact("Hexley Brandt is my \(word)", b, "Hexley Brandt")]]
        }.learn([secret], groups: [people])
        let id = try memory("My \(word) said Hexley Brandt would call.", .low, days: 1)
        let cloud = Scripted { _ in
            ["people": [Self.person("Hexley Brandt")], "roles": [["id": "r1", "refers_to": "someone_else"]]]
        }
        let report = try await extractor(cloud).learn([id], groups: [people])
        let notes = Set(report.calls.first?.dropped ?? [])
        #expect(notes.isSuperset(of: ["unseen_namesake", "unseen_holder"]))
        let g = try load()
        #expect(g.names[FactsGraph.NameKey(memoryID: id, surface: "Hexley Brandt")]?.basis == .ambiguous)
        #expect(!g.decisions.keys.contains { $0.memoryID == id })
    }

    // MARK: Reconciliation

    @Test func aChangeAboveTheLimitSelectsNoMemoryForACloudReRead() async throws {
        let sib = sibling
        for (i, n) in ["Maria Lopez", "Ines Vidal"].enumerated() {
            let id = try memory("My sister \(n) lives nearby.", .low, days: Double(i))
            try await local { _ in
                ["people": [Self.person(n)], "facts": [FactsExtractorTests.fact("My sister \(n)", sib, n, label: "sister")]]
            }.learn([id], groups: [people])
        }
        let phoned = try memory("My sister phoned.", .low, days: 3)
        try await extractor(Scripted { _ in [:] }).learn([phoned], groups: [people])
        // A third sister, known only from a restricted memory.
        let secret = try memory("My sister Petra Lind visited the clinic.", .restricted, days: 4)
        try await local { _ in
            ["people": [Self.person("Petra Lind")], "facts": [FactsExtractorTests.fact("My sister Petra Lind", sib, "Petra Lind", label: "sister")]]
        }.learn([secret], groups: [people])
        let users = user
        let (cloudDue, wholeDue) = try await v.store.writer.write { db in
            (try FactsReconciler.reconcile(db, only: phoned, userAliases: users, sendable: .upTo(.low)),
             try FactsReconciler.reconcile(db, only: phoned, userAliases: users))
        }
        #expect(cloudDue.isEmpty)
        #expect(!wholeDue.isEmpty)
        // A sendable change does select it.
        let third = try memory("My sister Clara Moss is visiting.", .low, days: 5)
        try await local { _ in
            ["people": [Self.person("Clara Moss")], "facts": [FactsExtractorTests.fact("My sister Clara Moss", sib, "Clara Moss", label: "sister")]]
        }.learn([third], groups: [people])
        let after = try await v.store.writer.write { db in
            try FactsReconciler.reconcile(db, only: phoned, userAliases: users, sendable: .upTo(.low))
        }
        #expect(!after.isEmpty)
    }

    // MARK: The user's names

    func sent(_ text: String, known: [String] = []) -> FactsSentText {
        FactsSentText(text, userAliases: user, registry: .bundled, namesakes: FactsNamesakes(fullNames: known))
    }

    @Test func theUserIsReplacedAndANamesakeWithAFullNameKeepsIt() {
        #expect(sent("Dani called. Dani Ortiz called too.").sent == "the user called. Dani Ortiz called too.")
        // A bare name after the namesake's full one could be either: the user (privacy fails closed).
        #expect(sent("Dani Ortiz called. Dani said hi.").sent == "Dani Ortiz called. the user said hi.")
        // The user's longer names, in any case; a one-word name only as written or in capitals.
        #expect(sent("dani ortega and DANI met dani.").sent == "the user and the user met dani.")
        let t = sent("Dani Ortiz called. Dani said hi.")
        #expect(t.locate("Dani Ortiz called. the user said").map(t.slice) == "Dani Ortiz called. Dani said")
    }

    @Test func aCapitalisedWordAfterTheNameIsntASurnameInATitleCapitalsOrADate() {
        #expect(sent("Dani Prefers Window Seats\nShe said so.").sent.hasPrefix("the user Prefers"))
        #expect(sent("DANI ORTIZ CALLED").sent == "the user ORTIZ CALLED")
        #expect(sent("I saw Dani Monday at noon.").sent == "I saw the user Monday at noon.")
        #expect(sent("Lunch with Dani March 3.").sent == "Lunch with the user March 3.")
    }

    @Test func aKnownFullNameKeepsItsFirstNameWhateverFollows() {
        #expect(sent("Lunch with Dani de la Cruz.").sent == "Lunch with the user de la Cruz.")
        #expect(sent("Lunch with Dani de la Cruz.", known: ["Dani de la Cruz"]).sent == "Lunch with Dani de la Cruz.")
        #expect(sent("DANI DE LA CRUZ", known: ["Dani de la Cruz"]).sent == "DANI DE LA CRUZ")
    }

    @Test func theUsersNamesAreNeverAddedNorInARoster() async throws {
        let id = try memory("Dani Ortiz called; Dani Ortiz is my colleague.")
        let cloud = Scripted { _ in ["people": [Self.person("Dani", "Dani Ortiz called"), Self.person("Dani Ortiz")]] }
        let report = try await extractor(cloud).learn([id], groups: [people])
        #expect(report.calls.first?.dropped.contains("user_name") == true)
        // An entity named like the user (from before the profile had the name) and the namesake's short alias.
        try await v.store.writer.write { db in
            let now = Date()
            try db.execute(sql: "INSERT INTO entity (id, kind, name, created_at, updated_at) VALUES ('old', 'person', 'Dani', ?, ?)", arguments: [now, now])
            try db.execute(sql: "INSERT INTO entity_alias (id, entity_id, alias, normalized, manual) VALUES ('oa', 'old', 'Dani', 'dani', 1)")
        }
        let next = try memory("Lunch on Friday.", days: 1)
        let a = try #require(try extractor(cloud).prepare(next, group: people))
        #expect(a.roster.text.contains("Dani Ortiz"))
        #expect(!a.roster.text.split(separator: "\n").contains { $0.hasPrefix("- e") && $0.contains("Dani") && !$0.contains("Dani Ortiz") })
    }

    @Test func aPhraseAndItsPairAreSentAsTheTextSentHasThem() async throws {
        let id = try memory("Notes From Dani Ortiz Today\nMy colleague Dani Ortiz and Dani's sister came.")
        let cloud = Scripted { _ in [:] }
        try await extractor(cloud).learn([id], groups: [people])
        let prompt = Self.sent(cloud)
        #expect(prompt.contains("Notes From the user Ortiz Today"))
        #expect(prompt.contains("\"the user's sister\""))
        #expect(!prompt.contains("Dani's"))
    }

    // MARK: Review of the diff

    @Test func aRestrictedRestatementChangesNothingACloudCallSeesNorSelects() async throws {
        let sib = sibling
        var ids: [String] = []
        for (i, n) in ["Maria Lopez", "Ines Vidal"].enumerated() {
            let id = try memory("My sister \(n) lives nearby.", .low, days: Double(i))
            ids.append(id)
            try await local { _ in
                ["people": [Self.person(n)], "facts": [FactsExtractorTests.fact("My sister \(n)", sib, n, label: "sister")]]
            }.learn([id], groups: [people])
        }
        let phoned = try memory("My sister phoned.", .low, days: 3)
        try await extractor(Scripted { _ in [:] }).learn([phoned], groups: [people])
        let before = try load(.upTo(.low))
        let secret = try memory("My sister Maria Lopez is my former sister now, the Thornwick note says.", .restricted, days: 4)
        try await local { r in
            ["people": [Self.person("Maria Lopez", nil, FactsExtractorTests.rosterID(r.prompt, "Maria Lopez"))],
             "facts": [FactsExtractorTests.fact("My sister Maria Lopez", sib, "Maria Lopez", label: "sister", status: "former")]]
        }.learn([secret], groups: [people])
        let after = try load(.upTo(.low))
        let maria = try #require(entity(after, "Maria Lopez"))
        let fact = { (g: FactsGraph) in g.facts.first { $0.entity == maria.id && $0.predicate == sib } }
        #expect(fact(after) != nil && fact(after).map { after.status(of: $0) } == fact(before).map { before.status(of: $0) })
        let users = user
        let due = try await v.store.writer.write { db in
            try FactsReconciler.reconcile(db, only: phoned, userAliases: users, sendable: .upTo(.low))
        }
        #expect(due.isEmpty)
    }

    @Test func aStatementRestingOnAHiddenFactOfTheHolderIsDropped() async throws {
        let sib = sibling, b = boss, word = FX.word(boss)
        let coffee = try memory("Coffee with Ana Ruiz.", .low)
        let sister = try memory("Ana Ruiz is my sister.", .low, days: 1)
        let x = local { r in
            let text = FactsExtractorTests.memoryText(r.prompt)
            if text.contains("Coffee") { return ["people": [Self.person("Ana Ruiz")]] }
            let ana = FactsExtractorTests.rosterID(r.prompt, "Ana Ruiz")
            if text.contains("is my sister") {
                return ["people": [Self.person("Ana Ruiz", nil, ana)], "facts": [FactsExtractorTests.fact("Ana Ruiz is my sister", sib, "Ana Ruiz", entity: ana)]]
            }
            return ["facts": [FactsExtractorTests.fact("My sister is now my \(word)", b, "Ana Ruiz", entity: ana)]]
        }
        try await x.learn([coffee, sister], groups: [people])
        let manager = try memory("My sister is now my \(word).", .low, days: 2)
        try await x.learn([manager], groups: [people])
        #expect(try load(.upTo(.low)).facts.contains { $0.predicate == b })
        // The sister memory turns out restricted: the boss statement came through what only it said.
        try await v.store.writer.write { db in
            try db.execute(sql: "UPDATE memory SET sensitivity = ? WHERE id = ?", arguments: [Sensitivity.restricted.rawValue, sister])
        }
        let g = try load(.upTo(.low))
        #expect(entity(g, "Ana Ruiz") != nil)
        #expect(!g.facts.contains { $0.predicate == b } && !g.facts.contains { $0.predicate == sib })
    }

    @Test func aSafeFullNameDoesntRescueAnUnsafeShortOne() async throws {
        let sib = sibling
        let secret = try memory("Ana Ruiz runs the clinic.", .restricted)
        let bell = try memory("Ana Bell visited. Ana is my sister.", .low, days: 1)
        try await local { r in
            let text = FactsExtractorTests.memoryText(r.prompt)
            if text.contains("Ana Ruiz") { return ["people": [Self.person("Ana Ruiz")]] }
            return ["people": [Self.person("Ana Bell"), Self.person("Ana", "Ana is my sister", "new")],
                    "facts": [FactsExtractorTests.fact("Ana is my sister", sib, "Ana")]]
        }.learn([secret, bell], groups: [people])
        let g = try load(.upTo(.low))
        #expect(!g.facts.contains { $0.predicate == sib })
    }

    @Test func aWithheldFactIsWithheldAcrossAMerge() async throws {
        let sib = sibling
        for (i, n) in ["Maria Lopez", "Mimi Lopez"].enumerated() {
            let id = try memory("My sister \(n) called.", .low, days: Double(i))
            try await local { _ in
                ["people": [Self.person(n)], "facts": [FactsExtractorTests.fact("My sister \(n)", sib, n, label: "sister")]]
            }.learn([id], groups: [people])
        }
        let whole = try load()
        let a = try #require(entity(whole, "Mimi Lopez")), b = try #require(entity(whole, "Maria Lopez"))
        let bid = b.id
        let fb = try #require(try await v.store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM fact WHERE entity_id = ? AND predicate = ?", arguments: [bid, sib])
        })
        try await v.store.writer.write { db in
            _ = try FactStore.override(db, targetKind: "qualifier", targetID: fb, field: "label", value: "Pemberly", sensitivity: Sensitivity.restricted.rawValue, now: t0)
            _ = try FactStore.override(db, targetKind: "entity", targetID: a.id, field: "merged_into", value: b.id, sensitivity: Sensitivity.low.rawValue, now: t0)
        }
        let g = try load(.upTo(.low))
        #expect(!g.facts.contains { $0.predicate == sib && !$0.negated })
    }

    @Test func aFactAddressedToAnUnseenNamesakesCandidateIsDropped() async throws {
        let sib = sibling
        let secret = try memory("Ana Ruiz runs the clinic.", .restricted)
        let bell = try memory("Ana Bell moved next door.", .low, days: 1)
        try await local { r in
            let text = FactsExtractorTests.memoryText(r.prompt)
            return ["people": [Self.person(text.contains("Ruiz") ? "Ana Ruiz" : "Ana Bell")]]
        }.learn([secret, bell], groups: [people])
        let id = try memory("Ana is my cousin.", .low, days: 2)
        let cloud = Scripted { r in
            let e = FactsExtractorTests.rosterID(r.prompt, "Ana Bell")
            return ["people": [Self.person("Ana", "Ana is my cousin", e)], "facts": [FactsExtractorTests.fact("Ana is my cousin", sib, "Ana", entity: e)]]
        }
        let report = try await extractor(cloud).learn([id], groups: [people])
        // The person, the fact addressed to them and the pair code applied through the name.
        #expect(report.calls.first?.dropped.filter { $0 == "unseen_namesake" }.count == 3)
        #expect(!(try load()).facts.contains { $0.predicate == sib })
    }

    @Test func aStaleDecisionIsntRevalidatedWithoutAHolderTheCallCouldntSee() async throws {
        let sib = sibling
        for (i, n) in ["Maria Lopez", "Ines Vidal"].enumerated() {
            let id = try memory("My sister \(n) lives nearby.", .low, days: Double(i))
            try await local { _ in
                ["people": [Self.person(n)], "facts": [FactsExtractorTests.fact("My sister \(n)", sib, n, label: "sister")]]
            }.learn([id], groups: [people])
        }
        let phoned = try memory("My sister phoned.", .low, days: 3)
        try await extractor(Scripted { r in ["roles": [["id": "r1", "refers_to": FactsExtractorTests.rosterID(r.prompt, "Maria Lopez")]]] })
            .learn([phoned], groups: [people])
        #expect(try load().decisions.keys.contains { $0.memoryID == phoned })
        try await v.store.writer.write { db in
            _ = try FactStore.addManualFact(db, predicate: sib, name: "Petra Lind", sensitivity: Sensitivity.restricted.rawValue, now: t0)
        }
        let users = user
        try await v.store.writer.write { db in _ = try FactsReconciler.reconcile(db, userAliases: users, sendable: .upTo(.low)) }
        // Still not counted: the whole graph doesn't get a link made without Petra.
        #expect(!(try load()).decisions.keys.contains { $0.memoryID == phoned })
    }

    @Test func aShortLineOrACapitalisedNonNameKeepsTheUserReplaced() {
        #expect(sent("Dani Travels\nOnly by train.").sent.hasPrefix("the user Travels"))
        #expect(sent("Dani NYC trip next week.").sent == "the user NYC trip next week.")
        #expect(sent("Dani Q3 goals.").sent == "the user Q3 goals.")
        #expect(FactsSentText("Dani Amazon order arrived.", userAliases: user, registry: .bundled,
                              namesakes: FactsNamesakes(thingWords: ["amazon"])).sent == "the user Amazon order arrived.")
        #expect(sent("Call Dani Ortiz tomorrow.").sent == "Call Dani Ortiz tomorrow.")
    }

    @Test func aLabelLearnedBeforeTheNameWasInAboutYouIsSentReplaced() async throws {
        let sib = sibling
        let id = try memory("My sister Maria Lopez, Dani's favourite, moved.")
        try await local { _ in
            ["people": [Self.person("Maria Lopez")], "facts": [FactsExtractorTests.fact("Maria Lopez, Dani's favourite", sib, "Maria Lopez", label: "Dani's favourite")]]
        }.learn([id], groups: [people])
        let next = try memory("Lunch on Friday.", days: 1)
        let a = try #require(try extractor(Scripted { _ in [:] }).prepare(next, group: people))
        #expect(a.roster.text.contains("Maria Lopez") && !a.roster.text.contains("Dani"))
    }

    @Test func somethingAboveTheLimitAddedLaterChangesNothingACloudCallSeesNorSelects() async throws {
        let sib = sibling
        let x = local { r in
            let text = FactsExtractorTests.memoryText(r.prompt)
            let maria = FactsExtractorTests.rosterID(r.prompt, "Maria Lopez"), bell = FactsExtractorTests.rosterID(r.prompt, "Ana Bell")
            if text.contains("Thornwick") {
                return ["people": [Self.person("Maria Lopez", nil, maria), Self.person("Ana Bell", nil, bell)],
                        "facts": [FactsExtractorTests.fact("Maria Lopez is my sister", sib, "Maria Lopez", entity: maria, label: "sister", status: "former"),
                                  FactsExtractorTests.fact("Ana Bell is my sister", sib, "Ana Bell", entity: bell, label: "sister")]]
            }
            for n in ["Maria Lopez", "Ines Vidal"] where text.contains(n) {
                return ["people": [Self.person(n)], "facts": [FactsExtractorTests.fact("My sister \(n)", sib, n, label: "sister")]]
            }
            if text.contains("praised") {
                return ["roles": [["id": "r1", "refers_to": maria]],
                        "facts": [FactsExtractorTests.fact("My sister praised my report", sib, "Maria Lopez", entity: maria, label: "sister")]]
            }
            for n in ["Ana Bell", "Ana Gray"] where text.contains(n) { return ["people": [Self.person(n)]] }
            return ["people": [Self.person("Ana", "Ana phoned", bell)]]
        }
        var ids: [String] = []
        for (i, t) in ["My sister Maria Lopez moved.", "My sister Ines Vidal called.", "Ana Bell moved next door.", "Ana Gray visited."].enumerated() {
            ids.append(try memory(t, .low, days: Double(i)))
        }
        try await x.learn(ids, groups: [people])
        let praised = try memory("My sister praised my report.", .low, days: 4)
        let phoned = try memory("Ana phoned last night.", .low, days: 5)
        try await x.learn([praised, phoned], groups: [people])
        let target = try memory("Lunch on Friday.", .low, days: 6)
        let cloud = extractor(Scripted { _ in [:] })
        let users = user
        func view() async throws -> (roster: String, decided: Bool, linked: Bool, statements: Int, due: Int) {
            let a = try #require(try cloud.prepare(target, group: people))
            let g = try load(.upTo(.low))
            let due = try await v.store.writer.write { db in
                try FactsReconciler.reconcile(db, userAliases: users, sendable: .upTo(.low)).count
            }
            return (a.roster.text, g.decisions.keys.contains { $0.memoryID == praised },
                    g.names[FactsGraph.NameKey(memoryID: phoned, surface: "Ana")] != nil,
                    g.facts.flatMap(\.assertions).filter { $0.memoryID == praised }.count, due)
        }
        let before = try await view()
        #expect(before.decided && before.linked && before.statements == 1)
        // Later, a restricted memory about Maria and Ana Bell: a restatement, and a fact only it states.
        let secret = try memory("Maria Lopez is my former sister, and Ana Bell is my sister, says the Thornwick file.", .restricted, days: 7)
        try await x.learn([secret], groups: [people])
        let after = try await view()
        #expect(after.roster == before.roster)
        #expect(after.linked && after.statements == 1 && after.due == before.due)
        // The whole graph has a new holder of the role, so the decision no longer counts there; one the call couldn't
        // see isn't a reason to ask the cloud again, so it isn't revalidated either: code resolves the phrase.
        #expect(!after.decided)
        #expect(!after.roster.contains("Thornwick"))
    }

    @Test func aRoleAnswerIsntDecidedWithoutHoldersACountAboveTheLimitSays() async throws {
        let sib = sibling
        for (i, n) in ["Maria Lopez", "Ines Vidal"].enumerated() {
            let id = try memory("My sister \(n) lives nearby.", .low, days: Double(i))
            try await local { _ in
                ["people": [Self.person(n)], "facts": [FactsExtractorTests.fact("My sister \(n)", sib, n, label: "sister")]]
            }.learn([id], groups: [people])
        }
        let three = try memory("I have three sisters, the clinic notes say.", .restricted, days: 2)
        try await local { _ in
            var count = FactsExtractorTests.fact("I have three sisters", sib, "", entity: "group", label: "sister")
            count["count"] = 3
            return ["facts": [count]]
        }.learn([three], groups: [people])
        let phoned = try memory("My sister phoned.", .low, days: 3)
        let report = try await extractor(Scripted { r in ["roles": [["id": "r1", "refers_to": FactsExtractorTests.rosterID(r.prompt, "Maria Lopez")]]] })
            .learn([phoned], groups: [people])
        #expect(report.calls.first?.dropped.contains("unseen_holder") == true)
        #expect(!(try load()).decisions.keys.contains { $0.memoryID == phoned })
    }

    @Test func aRoleAnswerThroughAnAmbiguousNamesakeIsDropped() async throws {
        let sib = sibling
        let secret = try memory("Ana Ruiz runs the clinic.", .restricted)
        try await local { _ in ["people": [Self.person("Ana Ruiz")]] }.learn([secret], groups: [people])
        for (i, n) in ["Ana Bell", "Clara Moss"].enumerated() {
            let id = try memory("My sister \(n) called.", .low, days: Double(i + 1))
            try await local { _ in
                ["people": [Self.person(n)], "facts": [FactsExtractorTests.fact("My sister \(n)", sib, n, label: "sister")]]
            }.learn([id], groups: [people])
        }
        let id = try memory("My sister Ana phoned.", .low, days: 4)
        let cloud = Scripted { r in
            let bell = FactsExtractorTests.rosterID(r.prompt, "Ana Bell")
            return ["people": [Self.person("Ana", "My sister Ana phoned", bell)], "roles": [["id": "r1", "refers_to": bell]]]
        }
        let report = try await extractor(cloud).learn([id], groups: [people])
        #expect(report.calls.first?.dropped.filter { $0 == "unseen_namesake" }.count == 2)
        #expect(!(try load()).decisions.keys.contains { $0.memoryID == id })
    }

    /// A reader for the two timing tests: "Ana Ruiz is my sister" gives her the sister fact; "My sister is now my
    /// manager" states the boss fact through the roster.
    func sisterThenBoss() -> FactsExtractor {
        let sib = sibling, b = boss, word = FX.word(boss)
        return local { r in
            let text = FactsExtractorTests.memoryText(r.prompt)
            let ana = FactsExtractorTests.rosterID(r.prompt, "Ana Ruiz")
            if text.contains("Coffee") { return ["people": [Self.person("Ana Ruiz")]] }
            if text.contains("is my sister") {
                return ["people": [Self.person("Ana Ruiz", nil, ana)], "facts": [FactsExtractorTests.fact("Ana Ruiz is my sister", sib, "Ana Ruiz", entity: ana)]]
            }
            return ["facts": [FactsExtractorTests.fact("My sister is now my \(word)", b, "Ana Ruiz", entity: ana)]]
        }
    }

    @Test func aReReadOfTheSourceBeforeItsRaisedStillDropsWhatRestedOnIt() async throws {
        let b = boss, word = FX.word(boss)
        let x = sisterThenBoss()
        let coffee = try memory("Coffee with Ana Ruiz.", .low)
        let sister = try memory("Ana Ruiz is my sister.", .low, days: 1)
        try await x.learn([coffee, sister], groups: [people])
        let manager = try memory("My sister is now my \(word).", .low, days: 2)
        try await x.learn([manager], groups: [people])
        try await x.learn([sister], groups: [people])          // read again, later
        try await v.store.writer.write { db in
            try db.execute(sql: "UPDATE memory SET sensitivity = ? WHERE id = ?", arguments: [Sensitivity.restricted.rawValue, sister])
        }
        #expect(!(try load(.upTo(.low))).facts.contains { $0.predicate == b })
    }

    @Test func aRestrictedReadingEarlierInTheSameRunCountsAgainstALaterOne() async throws {
        let b = boss, word = FX.word(boss)
        let coffee = try memory("Coffee with Ana Ruiz.", .low)
        let sister = try memory("Ana Ruiz is my sister.", .restricted, days: 1)
        let manager = try memory("My sister is now my \(word).", .low, days: 2)
        try await sisterThenBoss().learn([coffee, sister, manager], groups: [people])     // one run
        let whole = try load()
        #expect(whole.facts.contains { $0.predicate == b })
        #expect(!(try load(.upTo(.low))).facts.contains { $0.predicate == b })
    }
}
