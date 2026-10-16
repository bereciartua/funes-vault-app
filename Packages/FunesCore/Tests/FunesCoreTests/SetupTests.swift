import Foundation
import GRDB
import Testing
@testable import FunesCore

@Suite struct SetupTests {
    @Test func supportDirectoryIsNamedFunesVault() throws {
        let url = try VaultLocation.supportDirectory()
        #expect(url.lastPathComponent == "FunesVault")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Application Support")
    }

    // The store relies on FTS5 (spec/architecture/storage.md); fail early if the
    // linked SQLite lacks it.
    @Test func sqliteHasFTS5() throws {
        let db = try DatabaseQueue()
        try db.write { db in
            try db.create(virtualTable: "probe", using: FTS5()) { t in
                t.column("body")
            }
            try db.execute(sql: "INSERT INTO probe(body) VALUES ('remember the milk')")
            let hits = try Int.fetchOne(db, sql: "SELECT count(*) FROM probe WHERE probe MATCH 'milk'")
            #expect(hits == 1)
        }
    }
}
