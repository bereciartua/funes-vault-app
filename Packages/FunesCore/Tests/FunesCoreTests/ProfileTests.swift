import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Phase 8.1: About you (FR-U-01, FR-U-03; ADR-0026, access policy §3.10).
@Suite struct ProfileTests {
    typealias F = PolicyFixture

    /// The profile vectors' fixture: given "Martin", family "Bereciartua", no preferred name,
    /// pronouns "he/him", languages en and es, no location.
    static let martin = Profile(givenName: "Martin", familyName: "Bereciartua", pronouns: "he/him", languages: ["en", "es"])
    static let martinName = SharedProfile.Name(given: "Martin", family: "Bereciartua", called: "Martin")

    func fixture() async throws -> ServiceFixture {
        let fx = try ServiceFixture()
        try await ProfileService(store: fx.store, activity: fx.activity).save(Self.martin, now: fx.now)
        return fx
    }

    // MARK: Vectors T36–T46

    @Test func t36TheNameGoesWithANeedsApprovalAnswer() async throws {
        let fx = try await fixture()
        let out = try await fx.request()
        #expect(out.status == .needsApproval && out.bundle == nil)
        #expect(out.profile == SharedProfile(name: Self.martinName))
        #expect(out.profile?.pronouns == nil && out.profile?.languages == nil)
    }

    @Test func t37AndT38GateDenialsCarryNoProfile() async throws {
        let paused = try await fixture()
        paused.pause.pause(until: .distantFuture)
        let a = try await paused.request()
        #expect(a.reason == .funesPaused && a.profile == nil)
        #expect(try await paused.disclosures.disclosure(requestID: a.requestID!)?.profileFieldsSent == [])

        let suggestOnly = try await fixture()
        try suggestOnly.setAccess { $0.operations = [.suggest] }
        let b = try await suggestOnly.request()
        #expect(b.reason == .operationNotAllowed && b.profile == nil)

        let agentPaused = try await fixture()
        try agentPaused.setAgent(paused: true)
        #expect(try await agentPaused.request().profile == nil)

        let expired = try await fixture()
        try expired.setAccess { $0.expiresAt = expired.now.plus(minutes: -1) }
        let c = try await expired.request()
        #expect(c.reason == .accessExpired && c.profile == nil)
    }

    @Test func t39NoMatchingMemoriesStillCarriesTheProfile() async throws {
        let fx = try await fixture()
        fx.retriever.set([])
        let out = try await fx.request("What's my name?")
        #expect(out.status == .denied && out.reason == .noMatchingMemories && out.withheld == [:])
        #expect(out.profile == SharedProfile(name: Self.martinName))
    }

    @Test func noAllowedMemoriesAndFulfilledCarryItToo() async throws {
        let none = try await fixture()
        none.retriever.set([none.id("m3"), none.id("m6")])
        let a = try await none.request()
        #expect(a.reason == .noAllowedMemories && a.profile?.name == Self.martinName)

        let open = try await fixture()
        try open.setAccess { $0.askBeforeSharing = false }
        let b = try await open.request()
        #expect(b.status == .fulfilled && b.bundle?.items.count == 2 && b.profile?.name == Self.martinName)
    }

    @Test func t40SharingNothingSendsNoProfileKey() async throws {
        let fx = try await fixture()
        try fx.setAccess { $0.profileFields = [] }
        let out = try await fx.request()
        #expect(out.status == .needsApproval && out.profile == nil)
        #expect(try await fx.disclosures.disclosure(requestID: out.requestID!)?.profileFieldsSent == [])
    }

    @Test func t41OnlySharedFieldsThatHaveAValue() async throws {
        let fx = try await fixture()
        try fx.setAccess { $0.profileFields = [.name, .pronouns, .location] }
        let out = try await fx.request()
        #expect(out.profile == SharedProfile(name: Self.martinName, pronouns: "he/him"))
        #expect(out.profile?.fields == [.name, .pronouns])
    }

    @Test func t42ChangingTheFieldsIsAnAccessChange() async throws {
        let fx = try await fixture()
        let agents = AgentService(store: fx.store, keys: InMemoryAgentKeyStore(), activity: fx.activity)
        let id = try await fx.request().requestID!
        let first = try #require(try await fx.disclosures.panel(requestID: id, now: fx.now))
        var access = try #require(try await agents.agent(id: fx.agentID)).access
        access.profileFields = [.name, .languages]
        let changed = try await agents.updateAccess(agentID: fx.agentID, access, now: fx.now)
        #expect(changed.revision == 2)
        let rebuilt = try #require(try await fx.disclosures.panel(requestID: id, now: fx.now))
        #expect(rebuilt.snapshotRevision != first.snapshotRevision)
        await #expect(throws: VaultError.snapshotChanged) {
            try await fx.disclosures.approve(requestID: id, snapshotRevision: first.snapshotRevision,
                                             memoryIDs: [fx.id("m1")], now: fx.now)
        }

        // An approved request fails delivery instead (as T15).
        let approved = try await fx.approved(["m2"])
        access.profileFields = [.name]
        try await agents.updateAccess(agentID: fx.agentID, access, now: fx.now)
        let out = try await fx.disclosures.deliver(requestID: approved, agentID: fx.agentID, now: fx.now)
        #expect(out.status == .needsApproval && out.reason == .policyChanged)
    }

    @Test func t43EditingTheProfileDoesntInvalidateARelease() async throws {
        let fx = try await fixture()
        let id = try await fx.approved(["m2"])
        var edited = Self.martin
        edited.pronouns = "they/them"
        try await ProfileService(store: fx.store, activity: fx.activity).save(edited, now: fx.now)
        let out = try await fx.disclosures.deliver(requestID: id, agentID: fx.agentID, now: fx.now.plus(minutes: 1))
        #expect(out.status == .delivered && out.bundle?.items.map(\.memoryID) == [fx.id("m2")])
    }

    @Test func t44GetMemoryRequestDoesntRepeatIt() async throws {
        let fx = try await fixture()
        let out = try await fx.disclosures.requestInCall(agentID: fx.agentID, MemoryRequest(task: "Draft my update"),
                                                         wait: .milliseconds(50), now: { fx.now })
        #expect(out.status == .needsApproval && out.profile?.name == Self.martinName)
        let id = try #require(out.requestID)
        let panel = try #require(try await fx.disclosures.panel(requestID: id, now: fx.now))
        try await fx.disclosures.approve(requestID: id, snapshotRevision: panel.snapshotRevision, memoryIDs: [fx.id("m2")], now: fx.now)
        let delivered = try await fx.disclosures.deliver(requestID: id, agentID: fx.agentID, now: fx.now)
        #expect(delivered.status == .delivered && delivered.bundle?.items.map(\.memoryID) == [fx.id("m2")])
        #expect(delivered.profile == nil)
    }

    @Test func t45ActivityRecordsFieldNamesOnly() async throws {
        let fx = try await fixture()
        let out = try await fx.request()
        #expect(try await fx.disclosures.disclosure(requestID: out.requestID!)?.profileFieldsSent == [.name])
        let row = try #require(fx.activity.events.last { $0.event == "request_memory" })
        #expect(row.profileFields == [.name])
        let all = String(decoding: try JSONEncoder().encode(fx.activity.events), as: UTF8.self)
        #expect(!all.contains("Martin") && !all.contains("Bereciartua") && !all.contains("he/him"))
        let stored = try await fx.store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT profile_fields_sent FROM disclosure WHERE id = ?", arguments: [out.requestID!.db])
        }
        #expect(stored == #"["name"]"#)
    }

    @Test func t46ASecretInTheProfileRefusesTheWholeSave() async throws {
        let fx = try await fixture()
        let profiles = ProfileService(store: fx.store, activity: fx.activity)
        var bad = Self.martin
        bad.pronouns = "she/her"
        bad.occupation = "Engineer, key sk-abcdefghijklmnopqrstuvwxyz0123"
        await #expect(throws: VaultError.secretLikeContent([.openAIStyleKey])) {
            try await profiles.save(bad, now: fx.now)
        }
        #expect(try await profiles.profile().pronouns == "he/him")
        #expect(try await profiles.profile().occupation == nil)
    }

    // MARK: Delivery in the call

    /// An in-call approval is still the `request_memory` answer, so it keeps the profile.
    @Test func inCallDeliveryKeepsTheProfile() async throws {
        let fx = try await fixture()
        async let call = fx.disclosures.requestInCall(agentID: fx.agentID, MemoryRequest(task: "Draft my update"),
                                                      wait: .seconds(5), now: { fx.now })
        var pending: [Disclosure] = []
        for _ in 0..<500 where pending.isEmpty {
            pending = try await fx.disclosures.pendingRequests(now: fx.now)
            if pending.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        }
        let id = try #require(pending.first?.id)
        let panel = try #require(try await fx.disclosures.panel(requestID: id, now: fx.now))
        try await fx.disclosures.approve(requestID: id, snapshotRevision: panel.snapshotRevision, memoryIDs: [fx.id("m2")], now: fx.now)
        let out = try await call
        #expect(out.status == .delivered && out.profile?.name == Self.martinName)
    }

    @Test func rateLimitedAnswersCarryNoProfile() async throws {
        let fx = try await fixture()
        _ = try await fx.disclosures.request(agentID: fx.agentID, MemoryRequest(task: "One"), now: fx.now, maxPendingApprovals: 1)
        let out = try await fx.disclosures.request(agentID: fx.agentID, MemoryRequest(task: "Two"), now: fx.now,
                                                   maxPendingApprovals: 1)
        #expect(out.reason == .rateLimited && out.profile == nil)
        #expect(try await fx.disclosures.disclosure(requestID: out.requestID!)?.profileFieldsSent == [])
    }

    // MARK: What goes

    @Test func everyFieldAndTheAutomaticTimeZone() async throws {
        let fx = try ServiceFixture()
        let profiles = ProfileService(store: fx.store, activity: fx.activity)
        try await profiles.save(Profile(givenName: "Martin", preferredName: "Tincho", languages: ["es-AR", "en"],
                                        location: "Lisbon, Portugal", occupation: "Engineer"), now: fx.now)
        try fx.setAccess { $0.profileFields = Set(ProfileField.allCases) }
        let out = try await fx.request()
        #expect(out.profile == SharedProfile(name: .init(given: "Martin", family: nil, called: "Tincho"), languages: ["es-AR", "en"],
                                             location: "Lisbon, Portugal", timeZone: TimeZone.current.identifier,
                                             occupation: "Engineer"))
        #expect(out.profile?.fields == ProfileField.allCases.filter { $0 != .pronouns })
        let json = JSON.encode(out.profile)
        #expect(json.contains(#""time_zone":"#) && !json.contains("timeZone"))
    }

    @Test func aSetTimeZoneGoesAsSet() {
        let p = Profile(timeZone: "America/Argentina/Buenos_Aires")
        #expect(p.shared([.timeZone])?.timeZone == "America/Argentina/Buenos_Aires")
        #expect(Profile().shared([.timeZone], timeZone: TimeZone(identifier: "Europe/Lisbon")!)?.timeZone == "Europe/Lisbon")
        #expect(Profile().shared([.name, .pronouns]) == nil)
    }

    /// Rule 9: the profile's size is kept back, so a bundle filled to the limit still fits.
    @Test func theProfileIsKeptBackFromTheResultSize() async throws {
        let fx = try ServiceFixture()
        let long = String(repeating: "\"", count: 120)
        try await ProfileService(store: fx.store, activity: fx.activity).save(
            Profile(givenName: String(repeating: "\"", count: 80), location: long, occupation: long), now: fx.now)
        try fx.setAccess {
            $0.profileFields = Set(ProfileField.allCases)
            $0.askBeforeSharing = false
        }
        // Four memories that together leave about 1,200 bytes of the item budget: each is
        // 636 + 6 × 7,800 wire bytes ("Quotes n: " and 7,800 quote marks, plus the overhead).
        let ids = try await fx.store.writer.write { db in
            try (0..<4).map { i in
                try MemoryStore.insert(db, MemoryDraft(title: "Quotes \(i)", body: String(repeating: "\"", count: 7_800),
                                                       categoryKeys: ["communication_style"], sensitivity: .low),
                                       actor: .user, now: fx.now).id
            }
        }
        fx.retriever.set(ids)
        let full = try await fx.request(maxTokens: 8_000)
        let profile = try #require(full.profile)
        let items = try #require(full.bundle?.items)
        let itemBytes = items.reduce(0) { $0 + BundleCompiler.itemBytes(title: $1.title, text: $1.text) }
        #expect(profile.wireBytes > 1_000)
        #expect(itemBytes + profile.wireBytes <= BundleCompiler.maxItemBytes)
        #expect(items.count == 3)

        // Without the profile all four fit.
        try fx.setAccess { $0.profileFields = [] }
        let bare = try await fx.request(maxTokens: 8_000)
        #expect(bare.profile == nil && bare.bundle?.items.count == 4)
    }

    // MARK: Saving

    @Test func savingTrimsAndRecordsChangedFieldNames() async throws {
        let fx = try ServiceFixture()
        let profiles = ProfileService(store: fx.store, activity: fx.activity)
        #expect(try await profiles.profile() == Profile())
        #expect(try fx.store.profile().isEmpty)
        let saved = try await profiles.save(Profile(givenName: "  Martin ", familyName: "", languages: [" en", "EN", "es", ""]),
                                            now: fx.now)
        #expect(saved.givenName == "Martin" && saved.familyName == nil && saved.languages == ["en", "es"])
        #expect(saved.updatedAt == fx.now)
        #expect(fx.activity.events.last?.event == "profile_edited")
        #expect(fx.activity.events.last?.profileFields == [.name, .languages])
        let count = fx.activity.events.count
        try await profiles.save(saved, now: fx.now.plus(minutes: 1))
        #expect(fx.activity.events.count == count)
        #expect(try await profiles.profile().updatedAt == fx.now)
        var pronouns = saved
        pronouns.pronouns = "he/him"
        try await profiles.save(pronouns, now: fx.now.plus(minutes: 2))
        #expect(fx.activity.events.last?.profileFields == [.pronouns])
        #expect(try fx.store.profile().calledName == "Martin")
    }

    @Test func savingRefusesWhatsOverALimit() async throws {
        let fx = try ServiceFixture()
        let profiles = ProfileService(store: fx.store, activity: fx.activity)
        await #expect(throws: VaultError.invalidInput(field: "given_name")) {
            try await profiles.save(Profile(givenName: String(repeating: "a", count: 81)), now: fx.now)
        }
        await #expect(throws: VaultError.invalidInput(field: "languages")) {
            try await profiles.save(Profile(languages: ["en", "es", "fr", "de", "it", "pt", "nl", "sv", "da"]), now: fx.now)
        }
        await #expect(throws: VaultError.invalidInput(field: "languages")) {
            try await profiles.save(Profile(languages: ["not a tag"]), now: fx.now)
        }
        await #expect(throws: VaultError.invalidInput(field: "time_zone")) {
            try await profiles.save(Profile(timeZone: "Mars/Olympus_Mons"), now: fx.now)
        }
        try await profiles.save(Profile(givenName: String(repeating: "é", count: 80), timeZone: "Europe/Lisbon"), now: fx.now)
        #expect(try await profiles.profile().timeZone == "Europe/Lisbon")
    }

    @Test func sharingCountsAgentsThatCanRead() async throws {
        let fx = try ServiceFixture()
        let reader = try fx.addAgent(name: "Reader", access: Access(operations: [.read], profileFields: [.name, .pronouns]))
        _ = try fx.addAgent(name: "Suggester", access: Access(operations: [.suggest], profileFields: [.name, .pronouns]))
        let sharing = try await ProfileService(store: fx.store, activity: fx.activity).sharing()
        #expect(Set(sharing[.name]?.map(\.id) ?? []) == [fx.agentID, reader])
        #expect(sharing[.pronouns]?.map(\.id) == [reader])
        #expect(sharing[.location] == nil)
    }

    // MARK: Agents and access

    @Test func newAgentsShareTheirNameAndFieldsRoundTrip() async throws {
        let fx = try ServiceFixture()
        let agents = AgentService(store: fx.store, keys: InMemoryAgentKeyStore(), activity: fx.activity)
        let (added, _) = try await agents.create(name: "Cursor", kind: .cursor, now: fx.now)
        #expect(added.access.profileFields == [.name])
        #expect(try await agents.agent(id: added.id)?.access.profileFields == [.name])
        var access = added.access
        access.profileFields = [.languages, .timeZone]
        let saved = try await agents.updateAccess(agentID: added.id, access, now: fx.now)
        #expect(saved.access.profileFields == [.languages, .timeZone] && saved.revision == added.revision + 1)
        #expect(Access.Preset.nothingYet.access.profileFields == [.name])
    }

    // MARK: Export and import

    @Test func exportCarriesTheProfileAndImportRestoresItOnlyIntoAnEmptyOne() async throws {
        let source = try await fixture()
        let imports = ImportService(store: source.store, activity: source.activity)
        let data = try await imports.export(now: source.now)
        let export = try ImportParser.funesExport(data)
        #expect(export.profile?.givenName == "Martin" && export.profile?.languages == ["en", "es"])

        let empty = try ServiceFixture()
        let into = ImportService(store: empty.store, activity: empty.activity)
        let result = try await into.commit(try await into.preview(funesExport: export), asMemories: true, now: empty.now)
        #expect(result.restoredProfile)
        #expect(try empty.store.profile().familyName == "Bereciartua")

        let named = try ServiceFixture()
        try await ProfileService(store: named.store, activity: named.activity).save(Profile(givenName: "Alex"), now: named.now)
        let other = ImportService(store: named.store, activity: named.activity)
        let kept = try await other.commit(try await other.preview(funesExport: export), asMemories: true, now: named.now)
        #expect(!kept.restoredProfile)
        #expect(try named.store.profile() == Profile(givenName: "Alex", updatedAt: named.now))
    }

    @Test func anEmptyProfileIsLeftOutOfTheExport() async throws {
        let fx = try ServiceFixture()
        let data = try await ImportService(store: fx.store, activity: fx.activity).export(now: fx.now)
        #expect(try ImportParser.funesExport(data).profile == nil)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"profile\""))
    }

    // MARK: Migration

    /// Storage §3: a v0.4 (v5) vault migrates to v6 with a backup first; every agent not removed
    /// shares its name, removed ones nothing, and old requests sent no fields.
    @Test func migratesAVersion5Vault() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "funes-v5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "vault.sqlite")
        let active = UUID(), removed = UUID(), request = UUID()
        do {
            let queue = try DatabaseQueue(path: file.path)
            try Schema.migrator.migrate(queue, upTo: "v5_overview_indexes")
            try queue.write { db in
                for (id, name, removedAt) in [(active, "Claude Code", nil), (removed, "Old", t0 as Date?)] {
                    try db.execute(sql: """
                        INSERT INTO agent (id, name, agent_kind, created_at, removed_at) VALUES (?, ?, 'claude_code', ?, ?)
                        """, arguments: [id.db, name, t0, removedAt])
                    try db.execute(sql: "INSERT INTO access (agent_id, op_read) VALUES (?, 1)", arguments: [id.db])
                }
                try db.execute(sql: """
                    INSERT INTO disclosure (id, agent_id, agent_revision, task_hash, task_length, retention, max_tokens, status, created_at)
                    VALUES (?, ?, 1, 'h', 4, 'unknown', 1200, 'denied', ?)
                    """, arguments: [request.db, active.db, t0])
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let store = try VaultStore.open(directory: directory)
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "Backups").path)
        #expect(backups.contains { $0.hasPrefix("pre-v6_profile") })
        #expect(try store.agent(id: active)?.access.profileFields == [.name])
        #expect(try store.agent(id: removed)?.access.profileFields == [])
        #expect(try store.profile() == Profile())
        #expect(try store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM profile") } == 0)
        let d = try store.writer.read { db in try DisclosureService.fetch(db, id: request) }
        #expect(d?.profileFieldsSent == [])
        // One row at most.
        #expect(throws: (any Error).self) {
            try store.writer.write { db in try db.execute(sql: "INSERT INTO profile (id) VALUES (2)") }
        }
        #expect(try store.quickCheck())
    }
}
