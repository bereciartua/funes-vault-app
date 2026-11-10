import Foundation
import FunesCore
import Security
import Synchronization
import Testing
@testable import FunesCompanion

/// The Mac's companion identity moves to the data-protection Keychain without unpairing anyone
/// (the migration itself is `MigratingKeychainTests` in FunesCore; the real Keychains can't be
/// exercised in a test build).
@Suite struct MacIdentityKeychainTests {
    final class Keychains: KeychainBackend, @unchecked Sendable {
        let items = Mutex<[Bool: Data]>([:])
        let modernStatus: OSStatus?

        init(modernStatus: OSStatus? = nil) { self.modernStatus = modernStatus }

        func read(service: String, account: String, dataProtection: Bool) -> (status: OSStatus, data: Data?) {
            if dataProtection, let modernStatus { return (modernStatus, nil) }
            return items.withLock { $0[dataProtection] }.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        }

        func add(_ data: Data, service: String, account: String, dataProtection: Bool) -> OSStatus {
            if dataProtection, let modernStatus { return modernStatus }
            items.withLock { $0[dataProtection] = data }
            return errSecSuccess
        }

        func delete(service: String, account: String, dataProtection: Bool) -> OSStatus {
            if dataProtection, let modernStatus { return modernStatus }
            return items.withLock { $0.removeValue(forKey: dataProtection) } == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    @Test func anIdentityFromBeforeMovesAndStaysTheSame() throws {
        let keychains = Keychains()
        let original = MacIdentity()
        // Saved before: the legacy item only.
        keychains.items.withLock { $0[false] = try! JSONEncoder().encode(original.stored) }

        let loaded = try #require(try KeychainMacIdentityStore(service: "test", backend: keychains).loadOrCreate())
        #expect(loaded.macID == original.macID)
        #expect(loaded.signingKey.rawRepresentation == original.signingKey.rawRepresentation)
        #expect(loaded.hpkeKey.rawRepresentation == original.hpkeKey.rawRepresentation)
        #expect(keychains.items.withLock { $0[false] == nil && $0[true] != nil })
    }

    @Test func aBuildWithoutTheDataProtectionKeychainKeepsTheLegacyIdentity() throws {
        let keychains = Keychains(modernStatus: errSecMissingEntitlement)
        let original = MacIdentity()
        keychains.items.withLock { $0[false] = try! JSONEncoder().encode(original.stored) }
        let loaded = try KeychainMacIdentityStore(service: "test", backend: keychains).loadOrCreate()
        #expect(loaded.macID == original.macID)
        #expect(keychains.items.withLock { $0[false] != nil })
    }

    /// A locked data-protection Keychain with no legacy item is an error, so `loadOrCreate`
    /// doesn't make a new identity (which would unpair every phone).
    @Test func anUnreadableKeychainDoesNotMakeANewIdentity() {
        let keychains = Keychains(modernStatus: errSecInteractionNotAllowed)
        #expect(throws: CompanionKeychainError.status(errSecInteractionNotAllowed)) {
            try KeychainMacIdentityStore(service: "test", backend: keychains).loadOrCreate()
        }
    }
}
