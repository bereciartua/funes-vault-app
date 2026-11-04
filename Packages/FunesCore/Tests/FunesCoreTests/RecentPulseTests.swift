import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// FR-H-07: the menu bar panel's last 24 hours, hour by hour in the calendar's time zone.
@Suite struct RecentPulseTests {
    static let calendar = OverviewTests.calendar
    static let marker = "QXZ-PULSE-MARKER"

    /// t0 is 09:00 in Madrid; the panel opens at 09:30.
    static let now = t0.plus(minutes: 30)

    func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test func hoursAndTotals() throws {
        let vault = try TestVault()
        let m = Self.marker
        let (claude, cursor, gone) = try vault.store.writer.write { db in
            let seed = OverviewSeed(db: db)
            try seed.memory("Title \(m) 1", body: "Body \(m) 1", source: .manual, at: t0.plus(minutes: 10))
            try seed.memory("Title \(m) 2", body: "Body \(m) 2", source: .captureIPhone, at: t0.plus(minutes: -1))
            try seed.memory("Title \(m) 3", body: "Body \(m) 3", source: .agentWrite, at: t0.plus(minutes: -60 * 5))
            // Typed on a paired iPhone: `manual` with its device counts as the iPhone (ADR-0025).
            let device = UUID()
            try db.execute(sql: """
                INSERT INTO device (id, name, model, signing_public_key, hpke_public_key, paired_at) VALUES (?, 'iPhone', 'iPhone17,1', x'00', x'00', ?)
                """, arguments: [device.db, t0])
            try seed.memory("Title \(m) 6", body: "Body \(m) 6", source: .manual, at: t0.plus(minutes: -60 * 12))
            try db.execute(sql: "UPDATE memory SET source_device_id = ? WHERE title = ?", arguments: [device.db, "Title \(m) 6"])
            // Before the first hour: outside. In the next hour (a clock moved back): outside.
            try seed.memory("Title \(m) 4", body: "Body \(m) 4", source: .manual, at: t0.plus(minutes: -60 * 23 - 1))
            try seed.memory("Title \(m) 5", body: "Body \(m) 5", source: .manual, at: t0.plus(minutes: 60))
            let claude = try seed.agent("Claude Code", kind: .claudeCode)
            let cursor = try seed.agent("Cursor", kind: .cursor)
            let gone = try seed.agent("Gone Agent", kind: .zed, removed: t0.plus(days: -1))
            try seed.delivered(claude, at: t0.plus(minutes: 5), items: [(.low, "project_context"), (.low, "health"), (.internal, "finance")])
            try seed.delivered(cursor, at: t0.plus(minutes: -60 * 6), items: [(.low, "project_context")])
            try seed.delivered(gone, at: t0.plus(minutes: -60 * 4), items: [(.public, "finance")])
            try seed.delivered(claude, at: t0.plus(days: -2), items: [(.low, "project_context")])
            try seed.disclosure(claude, status: .denied, at: t0.plus(minutes: -30), reason: .deniedByUser)
            try seed.disclosure(cursor, status: .needsApproval, at: t0.plus(minutes: -20))
            return (claude, cursor, gone)
        }
        let pulse = try vault.store.recentPulse(now: Self.now, calendar: Self.calendar)

        #expect(pulse.hours.count == 24)
        #expect(pulse.timeZone == "Europe/Madrid")
        #expect(pulse.hours.last?.date == t0)
        #expect(pulse.hours.first?.date == t0.plus(minutes: -60 * 23))
        #expect(pulse.hours[23].inbound == VaultOverview.Sources(mac: 1))
        #expect(pulse.hours[22].inbound == VaultOverview.Sources(iphone: 1))
        #expect(pulse.hours[18].inbound == VaultOverview.Sources(agent: 1))
        #expect(pulse.hours[11].inbound == VaultOverview.Sources(iphone: 1))
        #expect(pulse.hours[23].out == [claude.db: 3])
        #expect(pulse.hours[17].out == [cursor.db: 1])
        #expect(pulse.hours[19].out == [gone.db: 1])
        #expect(pulse.hours[22].refused == 1)
        #expect(pulse.inbound == VaultOverview.Sources(mac: 1, iphone: 2, agent: 1))
        #expect(pulse.shared == 5)
        #expect(pulse.refused == 1)
        #expect(!pulse.isQuiet)
        #expect(pulse.agentNames == [claude.db: "Claude Code", cursor.db: "Cursor", gone.db: "Gone Agent"])
        #expect(RecentPulse.interval(of: pulse.hours[23]) == DateInterval(start: t0, duration: 3_600))

        // Counts and names only: no memory text or title anywhere in it.
        let json = String(decoding: try JSONEncoder().encode(pulse), as: UTF8.self)
        #expect(!json.contains(m))
        #expect(!json.contains("Title"))
        #expect(!json.contains("Body"))
    }

    @Test func emptyVault() throws {
        let vault = try TestVault()
        let pulse = try vault.store.recentPulse(now: Self.now, calendar: Self.calendar)
        #expect(pulse.hours.count == 24)
        #expect(pulse.isQuiet)
        #expect(pulse.agentNames.isEmpty)
        #expect(pulse.hours.allSatisfy { $0.inbound.total == 0 && $0.out.isEmpty && $0.refused == 0 })
    }

    @Test func anHourEndsAtItsLastSecond() throws {
        let vault = try TestVault()
        // 09:59:59 and 10:00:00 in Madrid, read at 10:30.
        let ten = t0.plus(minutes: 60)
        try vault.store.writer.write { db in
            let seed = OverviewSeed(db: db)
            try seed.memory("A", body: "a", source: .manual, at: ten.addingTimeInterval(-1))
            try seed.memory("B", body: "b", source: .manual, at: ten)
        }
        let pulse = try vault.store.recentPulse(now: ten.plus(minutes: 30), calendar: Self.calendar)
        #expect(pulse.hours[23].date == ten)
        #expect(pulse.hours[23].inbound.total == 1)
        #expect(pulse.hours[22].inbound.total == 1)
    }

    /// 28 March 2027: Madrid's clocks go from 02:00 to 03:00, so the last 24 hours span 25 clock
    /// hours; still 24 buckets of an hour each.
    @Test func springForwardStillMakesTwentyFourHours() throws {
        let vault = try TestVault()
        let now = utc("2027-03-28T10:30:00Z") // 12:30 CEST
        try vault.store.writer.write { db in
            // 01:30 CET and 03:30 CEST: one elapsed hour apart, in neighbouring buckets.
            try OverviewSeed(db: db).memory("A", body: "a", source: .manual, at: utc("2027-03-28T00:30:00Z"))
            try OverviewSeed(db: db).memory("B", body: "b", source: .manual, at: utc("2027-03-28T01:30:00Z"))
        }
        let pulse = try vault.store.recentPulse(now: now, calendar: Self.calendar)
        #expect(pulse.hours.count == 24)
        #expect(zip(pulse.hours, pulse.hours.dropFirst()).allSatisfy { $1.date.timeIntervalSince($0.date) == 3_600 })
        #expect(pulse.hours.last?.date == utc("2027-03-28T10:00:00Z"))
        let a = try #require(pulse.hours.firstIndex { $0.inbound.total == 1 })
        #expect(pulse.hours[a + 1].inbound.total == 1)
        #expect(Self.calendar.component(.hour, from: pulse.hours[a].date) == 1)
        #expect(Self.calendar.component(.hour, from: pulse.hours[a + 1].date) == 3)
    }

    /// 31 October 2027: 03:00 CEST becomes 02:00 CET, so 02:00–03:00 happens twice: two buckets.
    @Test func aRepeatedHourIsTwoBuckets() throws {
        let vault = try TestVault()
        let now = utc("2027-10-31T11:30:00Z") // 12:30 CET
        try vault.store.writer.write { db in
            try OverviewSeed(db: db).memory("A", body: "a", source: .manual, at: utc("2027-10-31T00:30:00Z")) // 02:30 CEST
            try OverviewSeed(db: db).memory("B", body: "b", source: .manual, at: utc("2027-10-31T01:30:00Z")) // 02:30 CET
        }
        let pulse = try vault.store.recentPulse(now: now, calendar: Self.calendar)
        #expect(pulse.hours.count == 24)
        #expect(zip(pulse.hours, pulse.hours.dropFirst()).allSatisfy { $1.date.timeIntervalSince($0.date) == 3_600 })
        let twos = pulse.hours.filter { Self.calendar.component(.hour, from: $0.date) == 2 }
        #expect(twos.count == 2)
        #expect(twos.map(\.inbound.total) == [1, 1])
        #expect(Self.calendar.timeZone.abbreviation(for: twos[0].date) != Self.calendar.timeZone.abbreviation(for: twos[1].date))
    }
}
