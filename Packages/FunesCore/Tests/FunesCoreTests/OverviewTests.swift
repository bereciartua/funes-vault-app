import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Raw rows for the overview's tests: agents, disclosures with their items, suggestions and
/// tidy-up runs, at chosen times.
struct OverviewSeed {
    let db: Database

    func agent(_ name: String, kind: AgentKind, removed: Date? = nil, lastRequest: Date? = nil) throws -> UUID {
        let id = UUID()
        try db.execute(sql: """
            INSERT INTO agent (id, name, agent_kind, created_at, removed_at, last_request_at) VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [id.db, name, kind.rawValue, t0.plus(days: -500), removed, lastRequest])
        return id
    }

    /// A delivered request with one item per `(sensitivity, category)`.
    func delivered(_ agent: UUID, at: Date, items: [(Sensitivity, String)], withheld: [String: Int] = [:],
                   snapshot: String? = nil) throws {
        let id = try disclosure(agent, status: .delivered, at: at, delivered: at, withheld: withheld, snapshot: snapshot)
        for (sensitivity, category) in items {
            try db.execute(sql: """
                INSERT INTO disclosure_item (disclosure_id, memory_id, memory_version, category_key, sensitivity, estimated_tokens)
                VALUES (?, ?, 1, ?, ?, 40)
                """, arguments: [id.db, UUID().db, category, sensitivity.rawValue])
        }
    }

    @discardableResult
    func disclosure(_ agent: UUID, status: DisclosureStatus, at: Date, delivered: Date? = nil, reason: ReasonCode? = nil,
                    withheld: [String: Int] = [:], snapshot: String? = nil) throws -> UUID {
        let id = UUID()
        try db.execute(sql: """
            INSERT INTO disclosure (id, agent_id, agent_revision, task_hash, task_length, retention, max_tokens, status, reason,
              withheld, candidate_snapshot, created_at, decided_at, delivered_at)
            VALUES (?, ?, 1, 'hash', 10, 'session', 2000, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id.db, agent.db, status.rawValue, reason?.rawValue, JSON.encode(withheld), snapshot, at, at, delivered])
        return id
    }

    func memory(_ title: String, body: String, source: MemorySource, at: Date, status: MemoryStatus = .active,
                sensitivity: Sensitivity = .low, kind: MemoryKind = .fact, categories: [String] = ["personal_preferences"]) throws {
        let id = UUID()
        try db.execute(sql: """
            INSERT INTO memory (id, title, body, kind, sensitivity, status, source, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id.db, title, body, kind.rawValue, sensitivity.rawValue, status.rawValue, source.rawValue, at, at])
        for key in categories {
            try db.execute(sql: "INSERT INTO memory_category (memory_id, category_key) VALUES (?, ?)", arguments: [id.db, key])
        }
    }

    func suggestion(_ title: String, body: String, at: Date, status: SuggestionStatus = .pending) throws {
        try db.execute(sql: """
            INSERT INTO suggestion (id, origin, title, body, status, created_at, expires_after) VALUES (?, 'capture_mac', ?, ?, ?, ?, ?)
            """, arguments: [UUID().db, title, body, status.rawValue, at, at.plus(days: 30)])
    }

    func tidyUp(started: Date, finished: Date?) throws {
        try db.execute(sql: "INSERT INTO tidy_up_run (id, started_at, finished_at) VALUES (?, ?, ?)",
                       arguments: [UUID().db, started, finished])
    }
}

@Suite struct OverviewTests {
    /// Madrid, weeks from Monday: t0 is Friday 15 January 2027, 09:00 there.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        calendar.firstWeekday = 2
        return calendar
    }

    static let marker = "QXZ-OVERVIEW-MARKER"

    /// Midnight in Madrid `days` days from t0's day, plus `hours`.
    func local(days: Int, hours: Double = 12) -> Date {
        Self.calendar.date(byAdding: .day, value: days, to: Self.calendar.startOfDay(for: t0))!.addingTimeInterval(hours * 3_600)
    }

    struct Agents {
        var claude: UUID
        var cursor: UUID
        var gone: UUID
        var goneButShared: UUID
    }

    @discardableResult
    func seed(_ vault: TestVault) throws -> Agents {
        try vault.store.writer.write { db in
            let seed = OverviewSeed(db: db)
            let m = Self.marker
            try seed.memory("Title \(m) 1", body: "Body \(m) 1", source: .manual, at: local(days: 0, hours: 8), sensitivity: .low)
            // Typed on a paired iPhone: `manual`, with the device.
            let device = UUID()
            try db.execute(sql: """
                INSERT INTO device (id, name, model, signing_public_key, hpke_public_key, paired_at) VALUES (?, 'iPhone', 'iPhone17,1', x'00', x'00', ?)
                """, arguments: [device.db, t0])
            try seed.memory("Title \(m) 8", body: "Body \(m) 8", source: .manual, at: local(days: -2), sensitivity: .low)
            // 00:30 in Madrid is 23:30 UTC the day before: still today here.
            try seed.memory("Title \(m) 2", body: "Body \(m) 2", source: .captureIPhone, at: local(days: 0, hours: 0.5),
                            sensitivity: .internal, kind: .preference, categories: ["personal_preferences", "project_context"])
            try seed.memory("Title \(m) 3", body: "Body \(m) 3", source: .agentWrite, at: local(days: -1), sensitivity: .sensitive,
                            categories: ["health"])
            try seed.memory("Title \(m) 4", body: "Body \(m) 4", source: .importChatGPT, at: local(days: -5))
            try seed.memory("Title \(m) 5", body: "Body \(m) 5", source: .tidyUp, at: local(days: -10), status: .archived)
            try seed.memory("Title \(m) 6", body: "Body \(m) 6", source: .seedQuestion, at: local(days: -40))
            // Tomorrow (a clock that moved back): outside every range.
            try seed.memory("Title \(m) 7", body: "Body \(m) 7", source: .manual, at: local(days: 1))
            // With the device, only `manual` counts as the iPhone: the agent's memory stays the agent's.
            try db.execute(sql: "UPDATE memory SET source_device_id = ? WHERE title IN (?, ?)", arguments: [device.db, "Title \(m) 8", "Title \(m) 3"])

            let claude = try seed.agent("Claude Code", kind: .claudeCode, lastRequest: local(days: 0, hours: 9))
            let cursor = try seed.agent("Cursor", kind: .cursor, lastRequest: local(days: -3))
            let gone = try seed.agent("Old Agent", kind: .other, removed: local(days: -100))
            let goneButShared = try seed.agent("Gone Agent", kind: .zed, removed: local(days: -2))
            try seed.delivered(claude, at: local(days: 0, hours: 9),
                               items: [(.low, "project_context"), (.low, "personal_preferences"), (.internal, "project_context")],
                               withheld: ["above_sensitivity_ceiling": 2])
            try seed.delivered(cursor, at: local(days: -3), items: [(.low, "project_context")], withheld: ["denied_category": 1])
            try seed.delivered(goneButShared, at: local(days: -12), items: [(.public, "finance")])
            try seed.delivered(claude, at: local(days: -45), items: [(.low, "project_context")])
            try seed.disclosure(claude, status: .denied, at: local(days: 0, hours: 8.5), reason: .deniedByUser,
                                withheld: ["above_sensitivity_ceiling": 1])
            try seed.disclosure(cursor, status: .denied, at: local(days: -20), reason: .funesPaused)
            try seed.disclosure(cursor, status: .needsApproval, at: local(days: -1))

            try seed.suggestion("Suggestion \(m)", body: "Suggested \(m)", at: local(days: -2))
            try seed.suggestion("Later \(m)", body: "Later \(m)", at: local(days: 0, hours: 6))
            try seed.suggestion("Answered \(m)", body: "Answered \(m)", at: local(days: -9), status: .applied)
            try seed.tidyUp(started: local(days: -1, hours: 3), finished: local(days: -1, hours: 3.1))
            try seed.tidyUp(started: local(days: 0, hours: 3), finished: nil)
            return Agents(claude: claude, cursor: cursor, gone: gone, goneButShared: goneButShared)
        }
    }

    @Test func thirtyDaysByLocalDay() throws {
        let vault = try TestVault()
        let agents = try seed(vault)
        let o = try vault.store.overview(.days30, now: t0, calendar: Self.calendar)

        #expect(o.range == .days30)
        #expect(o.timeZone == "Europe/Madrid")
        #expect(o.generatedAt == t0)
        #expect(o.days.count == 30)
        #expect(o.days.last?.date == Self.calendar.startOfDay(for: t0))
        #expect(o.days.first?.date == local(days: -29, hours: 0))

        let today = try #require(o.days.last)
        #expect(today.inbound == VaultOverview.Sources(mac: 1, iphone: 1))
        #expect(today.out == [agents.claude.db: 3])
        #expect(today.refused == 1)
        #expect(o.days[28].inbound == VaultOverview.Sources(agent: 1))
        #expect(o.days[27].inbound == VaultOverview.Sources(iphone: 1))
        #expect(o.days[24].inbound == VaultOverview.Sources(import: 1))
        #expect(o.days[19].inbound == VaultOverview.Sources(tidy: 1))
        #expect(o.days[26].out == [agents.cursor.db: 1])
        #expect(o.days[17].out == [agents.goneButShared.db: 1])
        #expect(o.days[9].refused == 1)
        #expect(o.days.map(\.inbound.total).reduce(0, +) == 6)
        #expect(o.days.map(\.shared).reduce(0, +) == 5)

        #expect(o.thisWeek == VaultOverview.Week(saved: 5, shared: 4, agents: 2, refused: 1))
        #expect(o.total == 7)
        #expect(o.bySensitivity == ["low": 5, "internal": 1, "sensitive": 1])
        #expect(o.count(.low) == 5)
        #expect(o.byKind == ["fact": 6, "preference": 1])
        #expect(o.byCategory == ["personal_preferences": 6, "project_context": 1, "health": 1])
        #expect(o.sharedBySensitivity == ["low": 3, "internal": 1, "public": 1])
        #expect(o.sharedByCategory == ["project_context": 3, "personal_preferences": 1, "finance": 1])
        #expect(o.refusedByReason == ["denied_by_user": 1, "funes_paused": 1])
        // Only the refused requests' withholdings.
        #expect(o.withheld == ["above_sensitivity_ceiling": 1])

        #expect(o.agents.map(\.name) == ["Claude Code", "Cursor", "Gone Agent"])
        #expect(o.agents[0] == VaultOverview.AgentCount(id: agents.claude.db, name: "Claude Code", kind: .claudeCode, shared: 3,
                                                        requests: 2, lastRequestAt: local(days: 0, hours: 9)))
        #expect(o.agents[1].requests == 3)
        #expect(o.agents[2].kind == .zed)
        #expect(!o.agents.contains { $0.id == agents.gone.db })

        #expect(o.rhythm.counts.count == 84)
        #expect(o.rhythm.start == local(days: -83, hours: 0))
        #expect(o.rhythm.counts.last == 2)
        #expect(o.rhythm.counts.reduce(0, +) == 7)

        #expect(o.inboxPending == 2)
        #expect(o.oldestPendingAt == local(days: -2))
        #expect(o.lastTidyUpAt == local(days: -1, hours: 3.1))
    }

    @Test func weeksAndMonths() throws {
        let vault = try TestVault()
        let agents = try seed(vault)
        let weeks = try vault.store.overview(.weeks12, now: t0, calendar: Self.calendar)
        #expect(weeks.days.count == 12)
        // The week holding Friday 15 January 2027 began on Monday the 11th.
        #expect(weeks.days.last?.date == local(days: -4, hours: 0))
        #expect(weeks.days[10].date == local(days: -11, hours: 0))
        // Tomorrow's memory is in this week's bucket, though not in the 30 days' today.
        #expect(weeks.days.last?.inbound == VaultOverview.Sources(mac: 2, iphone: 2, agent: 1))
        #expect(weeks.days[10].inbound == VaultOverview.Sources(import: 1, tidy: 1))
        #expect(weeks.days[5].inbound == VaultOverview.Sources(mac: 1))
        #expect(weeks.days.map(\.shared).reduce(0, +) == 6)
        #expect(weeks.agents.first { $0.id == agents.claude.db }?.shared == 4)
        // The same everywhere else.
        #expect(weeks.thisWeek == VaultOverview.Week(saved: 5, shared: 4, agents: 2, refused: 1))

        let months = try vault.store.overview(.months12, now: t0, calendar: Self.calendar)
        #expect(months.days.count == 12)
        #expect(months.days.last?.date == Self.calendar.date(from: DateComponents(year: 2027, month: 1, day: 1)))
        #expect(months.days.first?.date == Self.calendar.date(from: DateComponents(year: 2026, month: 2, day: 1)))
        #expect(months.days.last?.inbound.total == 7)
        #expect(months.days[10].inbound == VaultOverview.Sources(mac: 1))
        #expect(months.days[10].out == [agents.claude.db: 1])
    }

    @Test func daysFollowDaylightSaving() throws {
        // Madrid moves to summer time on Sunday 28 March 2027: that day has 23 hours.
        let vault = try TestVault()
        let calendar = Self.calendar
        let monday = calendar.date(from: DateComponents(year: 2027, month: 3, day: 29, hour: 12))!
        let sunday = calendar.date(from: DateComponents(year: 2027, month: 3, day: 28))!
        try vault.store.writer.write { db in
            let seed = OverviewSeed(db: db)
            // 23:30 on Sunday, local: 21:30 UTC.
            try seed.memory("a", body: "a", source: .manual, at: sunday.addingTimeInterval(22.5 * 3_600))
            // 00:30 on Monday, local: 22:30 UTC on Sunday.
            try seed.memory("b", body: "b", source: .manual, at: sunday.addingTimeInterval(23.5 * 3_600))
        }
        let o = try vault.store.overview(.days30, now: monday, calendar: calendar)
        #expect(o.days[28].date == sunday)
        #expect(o.days[28].inbound.mac == 1)
        #expect(o.days[29].inbound.mac == 1)
    }

    @Test func anEmptyVault() throws {
        let vault = try TestVault()
        for range in OverviewRange.allCases {
            let o = try vault.store.overview(range, now: t0, calendar: Self.calendar)
            #expect(o.days.count == range.bucketCount)
            #expect(o.total == 0 && o.agents.isEmpty && o.inboxPending == 0)
            #expect(o.oldestPendingAt == nil && o.lastTidyUpAt == nil)
            #expect(o.thisWeek == VaultOverview.Week())
            #expect(o.rhythm.counts == Array(repeating: 0, count: 84))
        }
    }

    /// FR-H-01: counts only. Every memory and suggestion holds the marker in its title and body;
    /// the encoded overview never does, nor any memory id.
    @Test func noMemoryTextOrTitle() throws {
        let vault = try TestVault()
        try seed(vault)
        let created = try vault.memory("Created \(Self.marker)", "Through the store \(Self.marker)", now: local(days: -1))
        for range in OverviewRange.allCases {
            let json = String(decoding: try CompanionJSON.encoder().encode(try vault.store.overview(range, now: t0, calendar: Self.calendar)),
                              as: UTF8.self)
            #expect(!json.contains(Self.marker))
            #expect(!json.contains("Title") && !json.contains("Body") && !json.contains("Suggest"))
            #expect(!json.contains(created.id.db))
            let ids = try vault.store.writer.read { db in try String.fetchAll(db, sql: "SELECT id FROM memory") }
            #expect(ids.allSatisfy { !json.contains($0) })
        }
    }

    /// Storage §3: a v0.3 (v4) vault migrates to v5 with a backup first, keeps its data, and the
    /// overview's reads use the new indexes.
    @Test func migratesAVersion4Vault() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "funes-v4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "vault.sqlite")
        do {
            let queue = try DatabaseQueue(path: file.path)
            try Schema.migrator.migrate(queue, upTo: "v4_memory_processing")
            try queue.write { db in
                let seed = OverviewSeed(db: db)
                try seed.memory("Kept", body: "Kept body", source: .captureIPhone, at: local(days: -2))
                let agent = try seed.agent("Claude Code", kind: .claudeCode)
                try seed.delivered(agent, at: local(days: -1), items: [(.low, "personal_preferences")])
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let store = try VaultStore.open(directory: directory)
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "Backups").path)
        #expect(backups.contains { $0.hasPrefix("pre-v5_overview_indexes") })
        let o = try store.overview(.days30, now: t0, calendar: Self.calendar)
        #expect(o.days[27].inbound.iphone == 1 && o.days[28].shared == 1 && o.total == 1)
        let plans = try store.writer.read { db in
            try [
                "SELECT source FROM memory WHERE created_at >= '2027' AND created_at < '2028'",
                "SELECT agent_id FROM disclosure WHERE delivered_at >= '2027' AND delivered_at < '2028'",
                "SELECT agent_id FROM disclosure WHERE created_at >= '2027' AND created_at < '2028'",
                "SELECT sensitivity, kind FROM memory WHERE status = 'active'",
            ].map { try String.fetchAll(db, sql: "EXPLAIN QUERY PLAN \($0)", adapter: SuffixRowAdapter(fromIndex: 3)).joined() }
        }
        #expect(plans[0].contains("COVERING INDEX memory_created"))
        #expect(plans[1].contains("COVERING INDEX disclosure_delivered"))
        #expect(plans[2].contains("COVERING INDEX disclosure_created"))
        #expect(plans[3].contains("COVERING INDEX memory_status_shape"))
        #expect(try store.quickCheck())
    }

    @Test func bucketExpressionIsABinarySearch() throws {
        let bounds = (0...5).map { t0.plus(days: Double($0)) }
        let expression = BucketExpression(column: "x", boundaries: bounds)
        #expect(expression.sql.filter { $0 == "?" }.count == 4)
        let queue = try DatabaseQueue()
        let times = [t0, t0.plus(days: 0.5), t0.plus(days: 1), t0.plus(days: 3.9), t0.plus(days: 4.99)]
        let buckets = try queue.read { db in try times.map { try bucket(db, expression, $0) } }
        #expect(buckets == [0, 0, 1, 3, 4])
    }

    func bucket(_ db: Database, _ expression: BucketExpression, _ time: Date) throws -> Int? {
        try Int.fetchOne(db, sql: "WITH t(x) AS (SELECT ?) SELECT \(expression.sql) FROM t", arguments: [time] + expression.arguments)
    }
}
