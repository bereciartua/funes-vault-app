import Foundation
import FunesProtocol

/// When what the phone read from the Mac must leave it: Search's and the Inbox's lists, the open
/// approvals and the cached overview (companion protocol §6.1, §8). Only when the end of the
/// pairing is known: removed on the Mac (a refusal the Mac signed), or no pairing in the Keychain
/// (read back empty, found missing by the client, or unpaired). Never on the tracker's starting
/// "not paired" before the Keychain has been read, a Keychain read that failed (before the first
/// unlock, say), or an unsigned refusal, which the client reports as unreachable.
///
/// `PhoneModel` feeds it what happens and asks `shouldClear` after each.
public struct VaultRetention: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        /// The pairing was read from the Keychain: there, or not.
        case read(paired: Bool)
        /// The Keychain couldn't be read.
        case readFailed
        /// Pairing finished.
        case paired
        /// A capture delivery ended.
        case delivered(DeliveryOutcome)
        /// A call to the Mac failed.
        case callFailed(CompanionClientError)
    }

    /// The pairing is known to be gone.
    public private(set) var pairingGone = false
    /// The pairing hasn't been read yet, or the last read failed: read it (again) before acting
    /// on "not paired".
    public private(set) var needsRead = true

    public init() {}

    public mutating func handle(_ event: Event) {
        switch event {
        case let .read(paired):
            pairingGone = !paired
            needsRead = false
        case .readFailed:
            pairingGone = false
            needsRead = true
        case .paired:
            pairingGone = false
            needsRead = false
        case .delivered(.notPaired), .callFailed(.notPaired):
            // The client read the Keychain itself and found no pairing.
            pairingGone = true
        case .delivered, .callFailed:
            break
        }
    }

    /// Whether the Mac's data must leave the phone, with the connection in `reachability`.
    public func shouldClear(_ reachability: Reachability) -> Bool {
        switch reachability {
        case .revoked: true
        case .notPaired: pairingGone
        case .connecting, .connected, .unreachable, .failed: false
        }
    }
}
