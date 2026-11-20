import Foundation
import FunesProtocol
import GRDB
import Synchronization
import Testing
@testable import FunesCore

/// The privacy payload gate (Phase 13a.2 Gates; ADR-0032's "facts, orders and decisions stated only above the limit: 0
/// in any cloud input, including which memories are selected"), as differential tests. Two vaults are the same but for
/// what's above the cloud limit: one also has restricted memories that a local model read earlier (a restatement of a
/// sendable fact with a new label, a new holder of a role, an order edge between jobs) and a restricted manual entry.
/// Then the same new memories go through the facts lane, reconciliation's re-asks included, with each call group on a
/// cloud model, on two cloud models, or on a local model beside a cloud one (the roster limit is the cloud's for both).
/// Every request either vault makes must be the same, byte for byte (ids aside), and none may carry what's above the
/// limit. A schema retry happens in both. Test vaults only; no live calls.
@Suite(.serialized) struct FactsPrivacyGateTests {
    typealias Scripted = FactsExtractorTests.Scripted
    let user = ["Dani Ortega", "Dani"]
    let reg = FactsRegistry.bundled
    var people: String { reg.callGroups.keys.sorted().first { FactsPrompt.hasPeople($0, reg) }! }
    var work: String { reg.predicate(reg.timelinePredicates[0])!.callGroup }
    var sibling: String { FX.personPredicate { $0.lexicon.contains { $0.words.contains("sister") } } }
    var boss: String { FX.personExclusive }
    var job: String { reg.timelinePredicates[0] }

    /// What's above the limit says, which no cloud input may carry.
    static let sentinels = ["Thornwick", "Elise", "Globex", "Ines", "older sister", "2017-03"]
    /// Findings the privacy gate records as known issues: while there's one, no qualification record may ship
    /// (FactsQualificationTests and qualify.py check it).
    static let openFindings = 0

    enum Shape: CaseIterable { case oneCloud, twoCloud, localPeopleCloudWork, cloudPeopleLocalWork }

    /// The local model that read everything before, both groups: answers from the memory text.
    func earlier(_ r: StructuredRequest<FactsJSON>) -> [String: Any] {
        let t = FactsExtractorTests.memoryText(r.prompt), workCall = !r.schema.json.contains("\"people\"")
        func f(_ q: String, _ p: String, _ n: String, entity: String = "name", label: String? = nil, status: String = "current",
               start: String? = nil, followedBy: String? = nil) -> [String: Any] {
            var d = FactsExtractorTests.fact(q, p, n, entity: entity, label: label, status: status, start: start,
                                             qualifiers: p == job ? ["kind": "employee", "title": NSNull()] : [:])
            if let followedBy { d["followed_by"] = followedBy }
            return d
        }
        let maria = FactsExtractorTests.rosterID(r.prompt, "Maria Lopez")
        if workCall {
            if t.contains("joined Acme") { return ["facts": [f("I joined Acme as an analyst in 2019", job, "Acme", start: "2019")]] }
            if t.contains("Globex") { return ["facts": [f("before Acme I worked at Globex", job, "Globex", status: "former", followedBy: "Acme")]] }
            return [:]
        }
        if t.contains("Maria Lopez moved") {
            return ["people": [["name": "Maria Lopez", "quote": "Maria Lopez", "person": "new"]],
                    "facts": [f("My sister Maria Lopez", sibling, "Maria Lopez", label: "sister")]]
        }
        if t.contains("Karim Rook") {
            return ["people": [["name": "Karim Rook", "quote": "Karim Rook", "person": "new"]],
                    "facts": [f("My boss Karim Rook", boss, "Karim Rook", label: "boss")]]
        }
        if t.contains("Thornwick file") {
            return ["people": [["name": "Maria Lopez", "quote": "Maria Lopez", "person": maria]],
                    "facts": [f("Maria Lopez is my older sister", sibling, "Maria Lopez", entity: maria, label: "older sister")]]
        }
        if t.contains("Elise Vale") {
            return ["people": [["name": "Elise Vale", "quote": "Elise Vale", "person": "new"]],
                    "facts": [f("My boss is Elise Vale now", boss, "Elise Vale", label: "boss")]]
        }
        return [:]
    }

    /// The model reading the new memories: role answers from the roster it's shown, a new sister's name, and an answer
    /// that isn't the schema's the first time it reads "praised" (the extractor retries once).
    final class Later: GenerationProvider, @unchecked Sendable {
        let id: ProviderID
        let locality: Locality
        let modelID = "scripted-later"
        let retried: Retried
        let sib: String
        let seen = Mutex<[(instructions: String, prompt: String)]>([])
        init(_ locality: Locality, retried: Retried, sibling: String) {
            id = locality == .cloud ? "anthropic" : "ollama"
            self.locality = locality
            self.retried = retried
            sib = sibling
        }
        func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
            seen.withLock { $0.append((request.instructions, request.prompt)) }
            let t = FactsExtractorTests.memoryText(request.prompt)
            if t.contains("praised"), !retried.once() { throw ProviderError.invalidOutput }
            var out: [String: Any] = ["facts": [], "roles": [], "things": []]
            if request.schema.json.contains("\"people\"") {
                out["people"] = [] as [Any]
                if t.contains("Ana Bell") {
                    out["people"] = [["name": "Ana Bell", "quote": "Ana Bell", "person": "new"]]
                    out["facts"] = [FactsExtractorTests.fact("My sister Ana Bell", sib, "Ana Bell", label: "sister")]
                } else if t.contains("My sister") {
                    out["roles"] = [["id": "r1", "refers_to": FactsExtractorTests.rosterID(request.prompt, "Maria Lopez")]]
                } else if t.contains("My boss") {
                    out["roles"] = [["id": "r1", "refers_to": FactsExtractorTests.rosterID(request.prompt, "Karim Rook")]]
                }
            }
            let data = try JSONSerialization.data(withJSONObject: out)
            return (try HTTPClient.decode(String(decoding: data, as: UTF8.self), as: T.self), ProviderUsage(requests: 1))
        }
    }

    /// One vault through both phases; every request the second phase's models received, ids blanked.
    func run(_ shape: Shape, hidden: Bool, newHolder: Bool) async throws -> (requests: [String], local: [String]) {
        let v = try TestVault()
        let clock = FactsHarness.Clock()
        func add(_ text: String, _ s: Sensitivity, _ day: Double) throws -> String {
            let (title, body) = FactsHarness.split(text)
            return try v.memory(title, body, sensitivity: s, now: t0.plus(days: day)).id.db
        }
        var first = [try add("My sister Maria Lopez moved to Lisbon.", .low, 0), try add("I joined Acme as an analyst in 2019.", .low, 1),
                     try add("My boss Karim Rook approved my leave.", .low, 2)]
        if hidden {
            first += [try add("Maria Lopez is my older sister and before Acme I worked at Globex, says the Thornwick file.", .restricted, 3),
                      try add("My boss is Elise Vale now, says the Thornwick note.", .restricted, 4)]
        }
        let groups = reg.callGroups.keys.sorted()
        var before = FactsExtractor(store: v.store, router: ModelRouter(classifier: nil, onDevice: nil, cloudLimit: .upTo(.secret),
                                                                       factsModel: Scripted(locality: .localServer, earlier)),
                                    activity: InMemoryActivityLog(), userAliases: user, qualification: .unchecked)
        before.clock = { clock.now() }
        for id in first { try await before.learn([id], groups: groups) }
        if hidden {
            try await v.store.writer.write { db in
                _ = try FactStore.addManualFact(db, predicate: sibling, name: "Ines Vidal", sensitivity: Sensitivity.restricted.rawValue, now: t0)
                // And a correction above the limit: the user's own start date for Acme, entered as restricted.
                if let acme = try String.fetchOne(db, sql: """
                    SELECT f.id FROM fact f JOIN entity_alias a ON a.entity_id = f.entity_id WHERE a.alias = 'Acme' AND f.predicate = ? LIMIT 1
                    """, arguments: [job]) {
                    _ = try FactStore.addUserEvidence(db, factID: acme, asserted: ["start": "2017-03"], sensitivity: Sensitivity.restricted.rawValue, now: t0)
                }
            }
        }
        // The second phase: the same new memories in both vaults, through the lane.
        let retried = Retried()
        let cloud = Later(.cloud, retried: retried, sibling: sibling), other = Later(.cloud, retried: retried, sibling: sibling)
        let local = Later(.localServer, retried: retried, sibling: sibling)
        let models: [String: any GenerationProvider] = switch shape {
        case .oneCloud: [people: cloud, work: cloud]
        case .twoCloud: [people: cloud, work: other]
        case .localPeopleCloudWork: [people: local, work: cloud]
        case .cloudPeopleLocalWork: [people: cloud, work: local]
        }
        var x = FactsExtractor(store: v.store, router: ModelRouter(classifier: nil, onDevice: nil, cloudLimit: .upTo(.low), factsModels: models),
                               activity: InMemoryActivityLog(), userAliases: user, qualification: .unchecked)
        x.clock = { clock.now() }
        let queue = ProcessingQueue(store: v.store, activity: InMemoryActivityLog(), launchedAt: .distantPast, ungatedFacts: true)
        let worker = FactsQueueWorker(extractor: x)
        // The new sister makes "My sister" in the first new memory due again: reconciliation re-asks it.
        let next = ["My sister called about the trip.", "My boss praised the report.", "My previous job was in a small office."]
            + (newHolder ? ["My sister Ana Bell visited from Porto."] : []) + ["Maria Lopez sent photos from Lisbon."]
        for (i, text) in next.enumerated() {
            let id = try add(text, .low, Double(10 + i))
            try await v.store.writer.write { db in
                for g in groups {
                    try ProcessingQueue.enqueueFacts(db, memoryID: UUID(uuidString: id)!, version: 1, group: g, reason: .version(text: true), now: clock.now())
                }
            }
            _ = try await queue.drain(now: { clock.now() }) { job in try await worker.process(job) { _, _ in } }
        }
        func blank(_ p: Later) -> [String] {
            p.seen.withLock { $0 }.map { ($0.instructions + "\n" + $0.prompt)
                .replacingOccurrences(of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", with: "<id>",
                                      options: .regularExpression) }
        }
        return (blank(cloud) + blank(other) + blank(local), blank(local))
    }

    @Test(arguments: Shape.allCases) func whatsAboveTheLimitChangesNoRequestInAnyGroupOrModelShape(_ shape: Shape) async throws {
        let without = try await run(shape, hidden: false, newHolder: false), with = try await run(shape, hidden: true, newHolder: false)
        #expect(!with.requests.isEmpty)
        #expect(with.requests == without.requests, "\(shape): a request changed with what's above the limit")
        for s in Self.sentinels { #expect(!with.requests.contains { $0.contains(s) }, "\(shape): \(s) reached a model") }
        // The retry happened in both: one request more than new memories × groups.
        #expect(with.requests.count == 4 * reg.callGroups.count + 1, "\(with.requests.count) requests")
    }

    /// The Gates step's finding, fixed: a restricted restatement of a fact invalidated a sendable memory's `named`
    /// decision; code revalidated it with its dependencies at the current versions (a restricted holder of the role
    /// among them), so the sendable graph withheld it, and when a sendable change later made that phrase's holders
    /// change (a new sister), reconciliation re-asked that memory of the cloud model in this vault only. A `named`
    /// decision rests on the name its own memory gives, so a holder above the limit no longer withholds it: which
    /// memories are asked again is the same in both vaults, byte for byte.
    @Test(arguments: Shape.allCases) func aLaterSendableHolderChangeReAsksTheSameWithOrWithoutARestrictedRestatement(_ shape: Shape) async throws {
        let without = try await run(shape, hidden: false, newHolder: true), with = try await run(shape, hidden: true, newHolder: true)
        for s in Self.sentinels { #expect(!with.requests.contains { $0.contains(s) }, "\(shape): \(s) reached a model") }
        // The retry, and reconciliation's re-ask of "My sister called about the trip." (a new sister), in both vaults.
        #expect(with.requests.count == 5 * reg.callGroups.count + 2, "\(shape): \(with.requests.count) requests")
        #expect(with.requests.contains { FactsExtractorTests.memoryText($0).hasPrefix("My sister called") && $0.contains("Ana Bell") })
        #expect(with.requests == without.requests, "\(shape): which memory is asked again depends on what's above the limit")
    }

    /// Not vacuous: with no cloud model in either group, the roster is the whole graph, so the local model sees what a
    /// cloud call never may.
    @Test func aLocalModelInEveryGroupSeesWhatsAboveTheLimit() async throws {
        let v = try TestVault()
        let (title, body) = FactsHarness.split("My boss is Elise Vale now, says the Thornwick note.")
        let hidden = try v.memory(title, body, sensitivity: .restricted, now: t0).id.db
        let earlierModel = Scripted(locality: .localServer, earlier)
        var x = FactsExtractor(store: v.store, router: ModelRouter(classifier: nil, onDevice: nil, cloudLimit: .upTo(.low), factsModel: earlierModel),
                               activity: InMemoryActivityLog(), userAliases: user, qualification: .unchecked)
        try await x.learn([hidden], groups: [people])
        let (t2, b2) = FactsHarness.split("My boss praised the report.")
        let next = try v.memory(t2, b2, sensitivity: .low, now: t0.plus(days: 1)).id.db
        let seen = Scripted(locality: .localServer) { _ in [:] }
        x = FactsExtractor(store: v.store, router: ModelRouter(classifier: nil, onDevice: nil, cloudLimit: .upTo(.low), factsModel: seen),
                           activity: InMemoryActivityLog(), userAliases: user, qualification: .unchecked)
        try await x.learn([next], groups: [people])
        #expect(seen.seen.withLock { $0.contains { $0.prompt.contains("Elise Vale") } })
    }
}

/// One invalid answer per vault, then valid ones: `once()` is false the first time only.
final class Retried: Sendable {
    private let done = Mutex(false)
    func once() -> Bool { done.withLock { v in defer { v = true }; return v } }
}
