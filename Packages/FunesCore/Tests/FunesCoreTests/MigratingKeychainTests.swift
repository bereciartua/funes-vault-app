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
        var calls: [String] = []
    }
    let state = Mutex(State())

    private func key(_ service: String, _ account: String) -> String { service + "/" + account }

    func read(service: String, account: String, dataProtection: Bool) -> (status: OSStatus, data: Data?) {
        state.withLock { s in
            s.calls.append("read \(dataProtection ? "modern" : "legacy")")
            if dataProtection, let refused = s.modernRefuses { return (refused, nil) }
            let data = dataProtection ? s.modern[key(service, account)] : s.legacy[key(service, account)]
            return data.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        }
    }

    func add(_ data: Data, service: String, account: String, dataProtection: Bool) -> OSStatus {
        state.withLock { s in
            s.calls.append("add \(dataProtection ? "modern" : "legacy")")
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
        state.withLock { s in
            s.calls.append("delete \(dataProtection ? "modern" : "legacy")")
            if dataProtection {
                if let refused = s.modernRefuses { return refused }
                return s.modern.removeValue(forKey: key(service, account)) == nil ? errSecItemNotFound : errSecSuccess
            }
            if let fails = s.legacyDeleteFails { return fails }
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

    /// A legacy item that can't be deleted after the copy is left; the copy is what's read.
    @Test func aLegacyItemThatWontGoIsHarmless() throws {
        legacy(secret)
        fake.state.withLock { $0.legacyDeleteFails = errSecInteractionNotAllowed }
        #expect(try keychain.read(account: "openai") == secret)
        #expect(stored.modern == secret && stored.legacy == secret)
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
