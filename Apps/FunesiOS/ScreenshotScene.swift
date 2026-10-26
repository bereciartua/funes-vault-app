#if DEBUG
import FunesProtocol
import Foundation

/// The App Store screenshots (spec/release/app-store/screenshots.md): `-FunesScreenshot <scene>`
/// launches straight into demo mode on one screen, so `scripts/app_store_screenshots.sh` captures
/// each one without tapping through the simulator. Debug builds only.
enum ScreenshotScene: String {
    case home, share, save, access, search, inbox

    static var current: ScreenshotScene? {
        UserDefaults.standard.string(forKey: "FunesScreenshot").flatMap(ScreenshotScene.init(rawValue:))
    }

    var tab: RootView.Tab {
        switch self {
        case .search: .search
        case .inbox: .inbox
        case .home, .share, .save, .access: .home
        }
    }

    /// The request whose panel is open.
    var approval: ApprovalKind? {
        switch self {
        case .share: .share
        case .save: .save
        case .access: .access
        case .home, .search, .inbox: nil
        }
    }

    /// Search's query.
    var searchQuery: String? { self == .search ? "swift" : nil }
}
#endif

#if DEBUG
import CryptoKit
import FunesPhone

/// `-FunesConnection <state>` shows the status bar's states (UX: iPhone, Status bar) in the
/// simulator without a Mac: a made-up pairing with "Maya's MacBook Pro", in that state, with two
/// captures waiting. Nothing is checked; a new capture's delivery ends it. Debug builds only.
enum ConnectionScene: String {
    case connected, unreachable, localNetworkOff, failed, revoked

    static var current: ConnectionScene? {
        UserDefaults.standard.string(forKey: "FunesConnection").flatMap(ConnectionScene.init(rawValue:))
    }

    var record: PairingRecord {
        let payload = PairingQRPayload(pairingID: "scene", macID: UUID(), macName: "Maya's MacBook Pro",
                                       macSigningKey: P256.Signing.PrivateKey().publicKey,
                                       macHPKEKey: P256.KeyAgreement.PrivateKey().publicKey, secret: Data(count: 32),
                                       expiresAt: Date(), addresses: [PairingAddress(kind: .lan, host: "192.168.1.20", port: 47626)])
        return PairingRecord(payload: payload, confirmation: PairConfirmation(deviceID: UUID(), macID: payload.macID, confirm: Data()),
                             deviceName: "iPhone", pairedAt: Date())
    }

    var check: Result<MacConnection, CompanionClientError> {
        switch self {
        case .connected: .success(DemoVault().connection)
        case .unreachable: .failure(.unreachable(localNetworkDenied: false))
        case .localNetworkOff: .failure(.unreachable(localNetworkDenied: true))
        case .failed: .failure(.badResponse(status: 404))
        case .revoked: .failure(.refused(.revoked))
        }
    }

    /// Captures waiting on this iPhone.
    static let waiting = 2

    /// When Home's made-up snapshot was taken: "As of 10:42" today, or two hours ago before then.
    var snapshotTime: Date {
        let now = Date()
        let at = Calendar.current.date(bySettingHour: 10, minute: 42, second: 0, of: now) ?? now
        return at < now ? at : now.addingTimeInterval(-2 * 3_600)
    }
}
#endif
