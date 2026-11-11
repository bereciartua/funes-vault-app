import Foundation
import Security
import Synchronization
import Testing
@testable import FunesCore

/// Both Keychains in memory, with the failures the real ones can give.
final class FakeKeychains: KeychainBackend, @unchecked Sendable {
    struct State {
        var legacy: [String: Data] = [:]
        var modern: [String: Data] = [:]
        /// The data-protection Keychain's answer to everything when this build can't use it.
        var modernRefuses: OSStatus?
        /// A data-protection add that fails.
        var addFails: OSStatus?
        /// The data-protection Keychain stores something else than it was given.
        var corruptsCopies = false
        var legacyDeleteFails: OSStatus?
        /// How many legacy deletes fail before they work.
        var legacyDeleteFailures = Int.max
        /// Which data-protection reads (1-based) fail for a moment.
        var failingModernReads: Set<Int> = []
        var modernReads = 0
        /// Which login-keychain reads (1-based) fail for a moment.
        var failingLegacyReads: Set<Int> = []
        var legacyReads = 0
        var calls: [String] = []
        /// Run once when the `occurrence`th such call starts, outside the fake's lock.
        var hook: (call: String, occurrence: Int, action: @Sendable () -> Void)?
    }
    let state = Mutex(State())

    /// Records the call and runs its hook, if it's the one waited for.
    private func enter(_ call: String) {
        let action = state.withLock { s -> (@Sendable () -> Void)? in
            s.calls.append(call)
            guard let hook = s.hook, hook.call == call, s.calls.filter({ $0 == call }).count == hook.occurrence else { return nil }
            s.hook = nil
            return hook.action
        }
        action?()
    }

    private func key(_ service: String, _ account: String) -> String { service + "/" + account }

    func read(service: String, account: String, dataProtection: Bool) -> (status: OSStatus, data: Data?) {
        enter("read \(dataProtection ? "modern" : "legacy")")
        return state.withLock { s in
            if dataProtection, let refused = s.modernRefuses { return (refused, nil) }
            if dataProtection {
                s.modernReads += 1
                if s.failingModernReads.contains(s.modernReads) { return (errSecInteractionNotAllowed, nil) }
            } else {
                s.legacyReads += 1
                if s.failingLegacyReads.contains(s.legacyReads) { return (errSecInteractionNotAllowed, nil) }
            }
            let data = dataProtection ? s.modern[key(service, account)] : s.legacy[key(service, account)]
            return data.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        }
    }

    func add(_ data: Data, service: String, account: String, dataProtection: Bool) -> OSStatus {
        enter("add \(dataProtection ? "modern" : "legacy")")
        return state.withLock { s in
            if dataProtection {
                if let refused = s.modernRefuses ?? s.addFails { return refused }
                guard s.modern[key(service, account)] == nil else { return errSecDuplicateItem }
                s.modern[key(service, account)] = s.corruptsCopies ? Data("garbled".utf8) : data
            } else {
                guard s.legacy[key(service, account)] == nil else { return errSecDuplicateItem }
                s.legacy[key(service, account)] = data
            }
            return errSecSuccess
        }
    }

    func delete(service: String, account: String, dataProtection: Bool) -> OSStatus {
        enter("delete \(dataProtection ? "modern" : "legacy")")
        return state.withLock { s in
            if dataProtection {
                if let refused = s.modernRefuses { return refused }
                return s.modern.removeValue(forKey: key(service, account)) == nil ? errSecItemNotFound : errSecSuccess
            }
            if let fails = s.legacyDeleteFails, s.legacyDeleteFailures > 0 {
                s.legacyDeleteFailures -= 1
                return fails
            }
            return s.legacy.removeValue(forKey: key(service, account)) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
}

/// Moving the Mac's keys to the data-protection Keychain without ever losing one. The real
/// Keychains can't be exercised here (an unsigned test build gets `errSecMissingEntitlement`);
/// this tests the logic against a fake.
@Suite struct MigratingKeychainTests {
    let secret = Data("sk-the-key".utf8)
    let fake = FakeKeychains()
    var keychain: MigratingKeychain { MigratingKeychain(service: "com.funesvault.provider", backend: fake) }

    func legacy(_ data: Data?) { fake.state.withLock { $0.legacy["com.funesvault.provider/openai"] = data } }
    var stored: (legacy: Data?, modern: Data?) {
        fake.state.withLock { ($0.legacy["com.funesvault.provider/openai"], $0.modern["com.funesvault.provider/openai"]) }
    }

    @Test func theFirstReadMovesTheItemAndVerifiesBeforeDeleting() throws {
        legacy(secret)
        let keychain = self.keychain
        #expect(try keychain.read(account: "openai") == secret)
        #expect(stored.legacy == nil && stored.modern == secret)
        #expect(fake.state.withLock { $0.calls } == ["read modern", "read legacy", "add modern", "read modern", "delete legacy"])
        // Later reads find it in the data-protection Keychain alone.
        fake.state.withLock { $0.calls = [] }
        #expect(try keychain.read(account: "openai") == secret)
        #expect(fake.state.withLock { $0.calls } == ["read modern"])
    }

    @Test func aRefusedCopyKeepsTheLegacyItem() throws {
        legacy(secret)
        fake.state.withLock { $0.addFails = errSecInteractionNotAllowed }
        #expect(try keychain.read(account: "openai") == secret)
        #expect(stored.legacy == secret && stored.modern == nil)
    }

    @Test func aCopyThatDoesntReadBackKeepsTheLegacyItem() throws {
        legacy(secret)
        fake.state.withLock { $0.corruptsCopies = true }
        #expect(try keychain.read(account: "openai") == secret)
        #expect(stored.legacy == secret)
        #expect(stored.modern == nil)
    }

    /// Unsigned and test builds: the data-protection Keychain isn't there, the legacy item is
    /// used and kept, and new items go to the legacy Keychain, as before.
    @Test func withoutTheDataProtectionKeychainNothingChanges() throws {
        fake.state.withLock { $0.modernRefuses = errSecMissingEntitlement }
        legacy(secret)
        #expect(try keychain.read(account: "openai") == secret)
        #expect(stored.legacy == secret)
        try keychain.write(Data("new".utf8), account: "openai")
        #expect(stored.legacy == Data("new".utf8))
        try keychain.delete(account: "openai")
        #expect(stored.legacy == nil)
        #expect(try keychain.read(account: "openai") == nil)
    }

    @Test func newItemsGoToTheDataProtectionKeychain() throws {
        legacy(Data("old".utf8))
        try keychain.write(secret, account: "openai")
        #expect(stored.modern == secret && stored.legacy == nil)
    }

    @Test func deletesClearBoth() throws {
        fake.state.withLock {
            $0.legacy["com.funesvault.provider/openai"] = Data("a".utf8)
            $0.modern["com.funesvault.provider/openai"] = Data("b".utf8)
        }
        try keychain.delete(account: "openai")
        #expect(stored.legacy == nil && stored.modern == nil)
        #expect(try keychain.read(account: "openai") == nil)
    }

    /// A legacy item that can't be deleted after the copy is tried again on a later read, so it
    /// doesn't stay in the login keychain; once gone, reads stop asking.
    @Test func aLegacyItemThatWontGoIsDeletedOnALaterRead() throws {
        legacy(secret)
        fake.state.withLock {
            $0.legacyDeleteFails = errSecInteractionNotAllowed
            $0.legacyDeleteFailures = 1
        }
        let keychain = self.keychain
        #expect(try keychain.read(account: "openai") == secret)
        #expect(stored.modern == secret && stored.legacy == secret)
        #expect(try keychain.read(account: "openai") == secret)
        #expect(stored.modern == secret && stored.legacy == nil)
        fake.state.withLock { $0.calls = [] }
        #expect(try keychain.read(account: "openai") == secret)
        #expect(fake.state.withLock { $0.calls } == ["read modern"])
    }

    /// A leftover legacy copy whose read fails for a moment is checked again on the next read,
    /// and goes then.
    @Test func aLegacyLeftoverIsRetriedAfterAFailedRead() throws {
        fake.state.withLock {
            $0.modern["com.funesvault.provider/openai"] = secret
            $0.legacy["com.funesvault.provider/openai"] = secret
            $0.failingLegacyReads = [1]
        }
        let keychain = self.keychain
        #expect(try keychain.read(account: "openai") == secret)
        #expect(stored.legacy == secret)
        #expect(try keychain.read(account: "openai") == secret)
        #expect(stored.legacy == nil)
    }

    /// A login keychain that keeps refusing is asked a few times, not on every read.
    @Test func aLegacyReadThatKeepsFailingIsGivenUp() throws {
        fake.state.withLock {
            $0.modern["com.funesvault.provider/openai"] = secret
            $0.legacy["com.funesvault.provider/openai"] = secret
            $0.failingLegacyReads = Set(1...100)
        }
        let keychain = self.keychain
        for _ in 0..<6 { #expect(try keychain.read(account: "openai") == secret) }
        #expect(fake.state.withLock { $0.legacyReads } == 3)
    }

    /// After a downgrade an older build may write a different key to the login keychain: the
    /// later read doesn't delete it unseen (it stays, shadowed by the migrated copy).
    @Test func aDifferentLegacyItemIsNotDeletedOnRead() throws {
        fake.state.withLock {
            $0.modern["com.funesvault.provider/openai"] = secret
            $0.legacy["com.funesvault.provider/openai"] = Data("written by an older build".utf8)
        }
        let keychain = self.keychain
        #expect(try keychain.read(account: "openai") == secret)
        #expect(stored.legacy == Data("written by an older build".utf8))
    }

    /// Runs `work` on another thread when the fake reaches `call`, waiting a little for it: with
    /// the lock it can't run until the operation under way is done; without, it would land in
    /// the middle of it.
    func interleave(at call: String, occurrence: Int = 1, _ work: @escaping @Sendable () -> Void) -> DispatchGroup {
        let group = DispatchGroup()
        group.enter()
        fake.state.withLock {
            $0.hook = (call, occurrence, {
                Thread.detachNewThread {
                    work()
                    group.leave()
                }
                _ = group.wait(timeout: .now() + 0.3)
            })
        }
        return group
    }

    /// A save between a first read's copy and its read-back isn't lost to the old key.
    @Test func aSaveDuringAMigrationIsKept() throws {
        legacy(Data("old".utf8))
        let keychain = self.keychain
        let done = interleave(at: "read modern", occurrence: 2) { try? keychain.write(Data("new".utf8), account: "openai") }
        _ = try keychain.read(account: "openai")
        done.wait()
        #expect(try keychain.read(account: "openai") == Data("new".utf8))
        #expect(stored.legacy == nil)
    }

    /// A delete between a first read's legacy read and its copy isn't undone: a removed key
    /// doesn't come back.
    @Test func aDeleteDuringAMigrationStays() throws {
        legacy(secret)
        let keychain = self.keychain
        let done = interleave(at: "add modern") { try? keychain.delete(account: "openai") }
        _ = try keychain.read(account: "openai")
        done.wait()
        #expect(try keychain.read(account: "openai") == nil)
        #expect(stored.legacy == nil && stored.modern == nil)
    }

    /// Two first reads at once, with the third data-protection read failing for a moment. Had
    /// the second read landed between the first's copy and its read-back, it would have found
    /// the copy and deleted the legacy item, and the first's failed read-back would then have
    /// deleted the copy: both gone. The key is never lost.
    @Test func twoFirstReadsNeverLoseTheKey() throws {
        legacy(secret)
        fake.state.withLock { $0.failingModernReads = [3] }
        let keychain = self.keychain
        let other = MigratingKeychain(service: "com.funesvault.provider", backend: fake)
        let done = interleave(at: "read modern", occurrence: 2) { _ = try? other.read(account: "openai") }
        #expect(try keychain.read(account: "openai") == secret)
        done.wait()
        #expect(stored.modern == secret || stored.legacy == secret)
        #expect(try keychain.read(account: "openai") == secret)
    }

    /// A data-protection Keychain that fails for another reason (locked) with no legacy item is
    /// an error, never "no key": a missing Mac identity would make a new one and unpair phones.
    @Test func anUnexplainedFailureIsNotNone() {
        fake.state.withLock { $0.modernRefuses = errSecInteractionNotAllowed }
        #expect(throws: KeychainError.status(errSecInteractionNotAllowed)) { try keychain.read(account: "openai") }
    }

    @Test func providerKeysGoThroughIt() throws {
        legacy(secret)
        let store = KeychainProviderKeyStore(service: "com.funesvault.provider", backend: fake)
        #expect(try store.key(for: ProviderID(rawValue: "openai")) == "sk-the-key")
        #expect(stored.modern == secret && stored.legacy == nil)
    }
}
