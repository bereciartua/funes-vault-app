import Foundation
import FunesProtocol
import GRDB

extension VaultStore {
    /// The vault's counts for `range` (FR-H-01, ADR-0025): aggregates only, never memory text or
    /// titles, read in one snapshot by SQL over the existing tables. Days, weeks and months
    /// begin in `calendar`'s time zone.
    public func overview(_ range: OverviewRange, now: Date, calendar: Calendar = .current) throws -> VaultOverview {
        try writer.read { db in try OverviewStore.overview(db, range: range, now: now, calendar: calendar) }
    }

    /// The last 24 hours by hour, the current hour last (FR-H-07): new memories by source,
    /// memories delivered by agent and requests refused, with the agents' names. Counts only.
    /// The current hour starts in `calendar`'s time zone; the 24 buckets are each an hour long,
    /// so a daylight-saving change still makes 24, and a repeated hour is two.
    public func recentPulse(now: Date, calendar: Calendar = .current) throws -> RecentPulse {
        try writer.read { db in try OverviewStore.recentPulse(db, now: now, calendar: calendar) }
    }
}

/// The overview's queries. Times are GRDB's UTC text, which sorts as it reads, so bucket
/// boundaries are compared as text and a range is a plain `>= AND <` that an index on the column
/// can serve.
enum OverviewStore {
    static func overview(_ db: Database, range: OverviewRange, now: Date, calendar: Calendar) throws -> VaultOverview {
        let buckets = OverviewCalendar(calendar: calendar)
        let bounds = buckets.boundaries(range, now: now)
        let days = buckets.dayBoundaries(VaultOverview.Rhythm.days, now: now)
        let week = Array(days.suffix(8))
        let span: StatementArguments = [bounds.first!, bounds.last!]
        let bucket = { (column: String) in BucketExpression(column: column, boundaries: bounds) }

        var series = bounds.dropLast().map { VaultOverview.Bucket(date: $0) }

        // In: new memories by source. One typed on a paired iPhone is `manual` with its device.
        let inbound = bucket("created_at")
        for row in try Row.fetchAll(db, sql: """
            SELECT \(inbound.sql) AS b, source, source = 'manual' AND source_device_id IS NOT NULL AS phone, COUNT(*) AS n FROM memory
            WHERE created_at >= ? AND created_at < ? GROUP BY b, source, phone
            """, arguments: inbound.arguments + span) {
            guard let b: Int = row["b"], series.indices.contains(b) else { continue }
            add(row["n"], source: row["phone"] ? MemorySource.captureIPhone.rawValue : row["source"], to: &series[b].inbound)
        }

        // Out: memories delivered, by agent, and by the sensitivity and category they were shared
        // at. One join for the three, each request's items costing a lookup, with each request's
        // bucket worked out once; SQL folds it to a few rows of each kind.
        let out = bucket("delivered_at")
        var sharedBySensitivity: [String: Int] = [:], sharedByCategory: [String: Int] = [:]
        for row in try Row.fetchAll(db, sql: """
            WITH d AS MATERIALIZED (
              SELECT id, agent_id, \(out.sql) AS b FROM disclosure WHERE delivered_at >= ? AND delivered_at < ?),
            x AS MATERIALIZED (
              SELECT d.b, d.agent_id, i.sensitivity, i.category_key, COUNT(*) AS n
              FROM d JOIN disclosure_item i ON i.disclosure_id = d.id GROUP BY d.b, d.agent_id, i.sensitivity, i.category_key)
            SELECT 'agent' AS by, b, agent_id AS key, SUM(n) AS n FROM x GROUP BY b, agent_id
            UNION ALL SELECT 'sensitivity', NULL, sensitivity, SUM(n) FROM x GROUP BY sensitivity
            UNION ALL SELECT 'category', NULL, category_key, SUM(n) FROM x GROUP BY category_key
            """, arguments: out.arguments + span) {
            let n: Int = row["n"]
            switch row["by"] as String {
            case "agent":
                if let b: Int = row["b"], series.indices.contains(b) { series[b].out[row["key"], default: 0] += n }
            case "sensitivity":
                if let level = row.sensitivity("key") { sharedBySensitivity[level.name] = n }
            default:
                sharedByCategory[row["key"]] = n
            }
        }

        // Refused requests, by day and by reason, and what they withheld (a few distinct
        // `{reason: count}` objects, decoded once each).
        let refused = bucket("created_at")
        var refusedByReason: [String: Int] = [:], withheld: [String: Int] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT \(refused.sql) AS b, reason, withheld, COUNT(*) AS n FROM disclosure
            WHERE status = 'denied' AND created_at >= ? AND created_at < ? GROUP BY b, reason, withheld
            """, arguments: refused.arguments + span) {
            let n: Int = row["n"]
            if let b: Int = row["b"], series.indices.contains(b) { series[b].refused += n }
            refusedByReason[(row["reason"] as String?) ?? "unknown", default: 0] += n
            for (reason, count) in JSON.decode([String: Int].self, row["withheld"]) ?? [:] { withheld[reason, default: 0] += count * n }
        }

        // The vault as it is: active memories by sensitivity, kind and category.
        var total = 0
        var bySensitivity: [String: Int] = [:], byKind: [String: Int] = [:], byCategory: [String: Int] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT sensitivity, kind, COUNT(*) AS n FROM memory WHERE status = 'active' GROUP BY sensitivity, kind
            """) {
            let n: Int = row["n"]
            total += n
            if let level = row.sensitivity("sensitivity") { bySensitivity[level.name, default: 0] += n }
            byKind[row["kind"], default: 0] += n
        }
        // Most memories are active: every category's count, less the inactive memories' (an
        // index-only scan and a few lookups, rather than a lookup per active memory).
        for row in try Row.fetchAll(db, sql: """
            SELECT category_key, COUNT(*) AS n FROM memory_category GROUP BY category_key
            """) {
            byCategory[row["category_key"]] = row["n"]
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT mc.category_key, COUNT(*) AS n FROM memory m JOIN memory_category mc ON mc.memory_id = m.id
            WHERE m.status IN ('archived', 'deleted') GROUP BY mc.category_key
            """) {
            let key: String = row["category_key"]
            byCategory[key] = (byCategory[key] ?? 0) - row["n"]
            if byCategory[key] == 0 { byCategory[key] = nil }
        }

        // Rhythm: new memories per day over 12 weeks; the last 7 are this week's.
        let daily = BucketExpression(column: "created_at", boundaries: days)
        var rhythm = Array(repeating: 0, count: VaultOverview.Rhythm.days)
        for row in try Row.fetchAll(db, sql: """
            SELECT \(daily.sql) AS b, COUNT(*) AS n FROM memory WHERE created_at >= ? AND created_at < ? GROUP BY b
            """, arguments: daily.arguments + [days.first!, days.last!]) {
            guard let b: Int = row["b"], rhythm.indices.contains(b) else { continue }
            rhythm[b] = row["n"]
        }

        // This week.
        let weekSpan: StatementArguments = [week.first!, week.last!]
        let delivered = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS n, COUNT(DISTINCT d.agent_id) AS agents FROM disclosure d JOIN disclosure_item i ON i.disclosure_id = d.id
            WHERE d.delivered_at >= ? AND d.delivered_at < ?
            """, arguments: weekSpan)
        let thisWeek = VaultOverview.Week(
            saved: rhythm.suffix(7).reduce(0, +), shared: (delivered?["n"] as Int?) ?? 0, agents: (delivered?["agents"] as Int?) ?? 0,
            refused: try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM disclosure WHERE status = 'denied' AND created_at >= ? AND created_at < ?
                """, arguments: weekSpan) ?? 0)

        // Agents: their requests and memories shared in the range.
        var requests: [String: Int] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT agent_id, COUNT(*) AS n FROM disclosure WHERE created_at >= ? AND created_at < ? GROUP BY agent_id
            """, arguments: span) {
            requests[row["agent_id"]] = row["n"]
        }
        var shared: [String: Int] = [:]
        for b in series { shared.merge(b.out, uniquingKeysWith: +) }
        let agents = try Row.fetchAll(db, sql: "SELECT id, name, agent_kind, last_request_at, removed_at FROM agent")
            .compactMap { row -> VaultOverview.AgentCount? in
                let id: String = row["id"]
                let removed = (row["removed_at"] as Date?) != nil
                guard !removed || shared[id] != nil || requests[id] != nil else { return nil }
                return VaultOverview.AgentCount(id: id, name: row["name"], kind: row.enumValue("agent_kind") ?? .other,
                                                shared: shared[id] ?? 0, requests: requests[id] ?? 0,
                                                lastRequestAt: row["last_request_at"])
            }
            .sorted { ($0.shared, $0.requests, $1.name) > ($1.shared, $1.requests, $0.name) }

        // The Inbox as `SuggestionService.pending()` lists it, and the last tidy-up.
        let inbox = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS n, MIN(created_at) AS oldest FROM suggestion s WHERE status = 'pending'
              AND NOT (group_id IS NOT NULL AND EXISTS (SELECT 1 FROM suggestion o WHERE o.id = s.group_id AND o.status = 'pending'))
            """)
        let lastTidyUp = try Date.fetchOne(db, sql: "SELECT MAX(finished_at) FROM tidy_up_run")

        return VaultOverview(
            range: range, generatedAt: now, timeZone: calendar.timeZone.identifier, total: total, thisWeek: thisWeek,
            days: series, rhythm: VaultOverview.Rhythm(start: days.first!, counts: rhythm), bySensitivity: bySensitivity,
            byCategory: byCategory, byKind: byKind, sharedBySensitivity: sharedBySensitivity, sharedByCategory: sharedByCategory,
            refusedByReason: refusedByReason, withheld: withheld, agents: agents, inboxPending: (inbox?["n"] as Int?) ?? 0,
            oldestPendingAt: inbox?["oldest"] as Date?, lastTidyUpAt: lastTidyUp)
    }

    /// The 25 boundaries of the last 24 hours: the current hour's start in `calendar`'s zone, and
    /// whole hours of elapsed time back from it.
    static func hourBoundaries(now: Date, calendar: Calendar) -> [Date] {
        let current = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let count = RecentPulse.hourCount
        return (0...count).map { current.addingTimeInterval(Double($0 - count + 1) * 3_600) }
    }

    static func recentPulse(_ db: Database, now: Date, calendar: Calendar) throws -> RecentPulse {
        let bounds = hourBoundaries(now: now, calendar: calendar)
        let span: StatementArguments = [bounds.first!, bounds.last!]
        var hours = bounds.dropLast().map { VaultOverview.Bucket(date: $0) }

        let inbound = BucketExpression(column: "created_at", boundaries: bounds)
        for row in try Row.fetchAll(db, sql: """
            SELECT \(inbound.sql) AS b, source, source = 'manual' AND source_device_id IS NOT NULL AS phone, COUNT(*) AS n FROM memory
            WHERE created_at >= ? AND created_at < ? GROUP BY b, source, phone
            """, arguments: inbound.arguments + span) {
            guard let b: Int = row["b"], hours.indices.contains(b) else { continue }
            add(row["n"], source: row["phone"] ? MemorySource.captureIPhone.rawValue : row["source"], to: &hours[b].inbound)
        }

        let out = BucketExpression(column: "d.delivered_at", boundaries: bounds)
        for row in try Row.fetchAll(db, sql: """
            SELECT \(out.sql) AS b, d.agent_id AS agent, COUNT(*) AS n FROM disclosure d JOIN disclosure_item i ON i.disclosure_id = d.id
            WHERE d.delivered_at >= ? AND d.delivered_at < ? GROUP BY b, d.agent_id
            """, arguments: out.arguments + span) {
            guard let b: Int = row["b"], hours.indices.contains(b) else { continue }
            hours[b].out[row["agent"], default: 0] += row["n"] as Int
        }

        let refused = BucketExpression(column: "created_at", boundaries: bounds)
        for row in try Row.fetchAll(db, sql: """
            SELECT \(refused.sql) AS b, COUNT(*) AS n FROM disclosure
            WHERE status = 'denied' AND created_at >= ? AND created_at < ? GROUP BY b
            """, arguments: refused.arguments + span) {
            guard let b: Int = row["b"], hours.indices.contains(b) else { continue }
            hours[b].refused += row["n"] as Int
        }

        let ids = Set(hours.flatMap(\.out.keys))
        var names: [String: String] = [:]
        if !ids.isEmpty {
            for row in try Row.fetchAll(db, sql: "SELECT id, name FROM agent WHERE id IN (\(databaseQuestionMarks(count: ids.count)))",
                                        arguments: StatementArguments(Array(ids))) {
                names[row["id"]] = row["name"]
            }
        }
        return RecentPulse(generatedAt: now, timeZone: calendar.timeZone.identifier, hours: hours, agentNames: names)
    }

    /// The chart's five sources (UX: Mac ▸ Home): the setup's questions count as the Mac, an
    /// unknown source (from a newer build) too.
    static func add(_ n: Int, source: String, to sources: inout VaultOverview.Sources) {
        switch MemorySource(rawValue: source) {
        case .captureIPhone: sources.iphone += n
        case .agentSuggestion, .agentWrite: sources.agent += n
        case .importChatGPT, .importClaude, .importMarkdown, .importFunes: sources.import += n
        case .tidyUp: sources.tidy += n
        case .manual, .captureMac, .seedQuestion, nil: sources.mac += n
        }
    }
}

/// The bucket of a time column as SQL: a balanced tree of `CASE WHEN column < boundary`, so a
/// row costs about log₂(buckets) comparisons in SQLite and no Swift. It's the index `i` with
/// `b[i] <= column < b[i+1]`; the query's `WHERE` keeps rows inside `[b[0], b[n])`.
struct BucketExpression {
    let sql: String
    let arguments: StatementArguments

    init(column: String, boundaries: [Date]) {
        var arguments: [any DatabaseValueConvertible] = []
        func tree(_ lo: Int, _ hi: Int) -> String {
            guard hi - lo > 1 else { return String(lo) }
            let mid = (lo + hi) / 2
            arguments.append(boundaries[mid])
            let below = tree(lo, mid)
            let above = tree(mid, hi)
            return "(CASE WHEN \(column) < ? THEN \(below) ELSE \(above) END)"
        }
        sql = tree(0, boundaries.count - 1)
        self.arguments = StatementArguments(arguments)
    }
}
