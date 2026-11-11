import Foundation
import FunesProtocol
import Testing
@testable import FunesPhone

/// When the iPhone clears what it read from the Mac (§6.1, §8): only once the pairing's end is
/// known. The app's PhoneModel feeds `VaultRetention` and the tracker the same events.
@Suite struct VaultRetentionTests {
    /// The two together, as PhoneModel runs them.
    struct Phone {
        var tracker = ReachabilityTracker()
        var retention = VaultRetention()
        var cleared = 0

        mutating func read(paired: Bool?) {
            if let paired { retention.handle(.read(paired: paired)) } else { retention.handle(.readFailed) }
            tracker.handle(.pairing(paired: paired == true))
            settle()
        }

        mutating func delivered(_ outcome: DeliveryOutcome) {
            retention.handle(.delivered(outcome))
            tracker.handle(.delivered(outcome))
            settle()
        }

        mutating func callFailed(_ error: CompanionClientError) {
            retention.handle(.callFailed(error))
            tracker.handle(.callFailed(error))
            settle()
        }

        mutating func settle() { if retention.shouldClear(tracker.state) { cleared += 1 } }
    }

    static let unreachable = CompanionClientError.unreachable(localNetworkDenied: false)

    /// Launch: the tracker starts "not paired" before the Keychain is read; that's no reason.
    @Test func launchBeforeThePairingIsRead() {
        var phone = Phone()
        #expect(phone.tracker.state == .notPaired && phone.retention.needsRead)
        phone.settle()
        #expect(phone.cleared == 0)
        phone.read(paired: true)
        #expect(phone.cleared == 0 && !phone.retention.needsRead)
    }

    /// A background refresh before the first read: a delivery that couldn't reach the Mac, or
    /// is still backing off, clears nothing.
    @Test func backgroundDeliveryBeforeTheFirstRead() {
        var phone = Phone()
        phone.delivered(.failed(Self.unreachable, retryAt: t0, sent: 0))
        phone.delivered(.waiting(until: t0))
        #expect(phone.cleared == 0)
    }

    /// The Keychain can't be read yet (before the first unlock): nothing goes, and it's read again.
    @Test func aTransientKeychainError() {
        var phone = Phone()
        phone.read(paired: nil)
        #expect(phone.tracker.state == .notPaired)
        #expect(phone.cleared == 0 && phone.retention.needsRead)
        phone.read(paired: true)
        #expect(phone.cleared == 0 && !phone.retention.needsRead)
        // A paired phone whose later read fails keeps everything too.
        phone.read(paired: nil)
        #expect(phone.cleared == 0)
    }

    @Test func anEmptyKeychain() {
        var phone = Phone()
        phone.read(paired: false)
        #expect(phone.cleared == 1)
    }

    /// The client finds no pairing itself (a delivery or a call): the Keychain is empty.
    @Test func theClientFindsNoPairing() {
        var phone = Phone()
        phone.delivered(.notPaired)
        #expect(phone.cleared == 1)
        var other = Phone()
        other.read(paired: true)
        other.callFailed(.notPaired)
        #expect(other.cleared == 1)
    }

    /// Unpair: the next read finds the Keychain empty. Pairing again keeps what comes next.
    @Test func unpair() {
        var phone = Phone()
        phone.read(paired: true)
        phone.read(paired: false)
        #expect(phone.cleared == 1)
        phone.retention.handle(.paired)
        phone.tracker.handle(.pairing(paired: true))
        phone.settle()
        #expect(phone.cleared == 1)
    }

    /// Removed on the Mac, which signed it: everything goes, by a call or a delivery.
    @Test func aSignedRevoke() {
        var phone = Phone()
        phone.read(paired: true)
        phone.callFailed(.refused(.revoked))
        #expect(phone.tracker.state == .revoked && phone.cleared == 1)
        var delivered = Phone()
        delivered.read(paired: true)
        delivered.delivered(.revoked)
        #expect(delivered.cleared == 1)
    }

    /// An unsigned refusal (another host, or a Mac before signed refusals) reaches the app as
    /// unreachable: nothing goes.
    @Test func anUnsignedRefusal() {
        var phone = Phone()
        phone.read(paired: true)
        phone.callFailed(Self.unreachable)
        phone.delivered(.failed(Self.unreachable, retryAt: t0, sent: 0))
        #expect(phone.tracker.state == .unreachable(localNetworkDenied: false) && phone.cleared == 0)
    }
}
