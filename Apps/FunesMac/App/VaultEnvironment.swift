import BridgeUI
import Foundation
import FunesCompanion
import FunesCore
import FunesMCP
import FunesProtocol
import os

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "vault")

/// The open vault and the services on it, for the app's lifetime.
@MainActor
final class VaultEnvironment {
    let dataFolder: URL
    let store: VaultStore
    let pause = FunesPause()
    let activity: ActivityLog
    let keys: AgentKeyFileStore
    let agents: AgentService
    let search: SearchService
    let disclosures: DisclosureService
    let suggestions: SuggestionService
    let captures: CaptureService
    let devices: DeviceService
    let imports: ImportService
    /// About you (ADR-0026).
    let profiles: ProfileService
    /// Inbox cards being edited and Save panels on screen: the tidy-up never withdraws one of
    /// them (memory processing §9.5).
    let holds = SuggestionHolds()
    /// Whether new inputs are split now; ProcessingRunner keeps it current (memory processing §5.2).
    let splitting = SplittingSwitch()
    private(set) var indexer: EmbeddingIndexer?
    private var observation: AnyObject?
    /// The Share, Save and access-request panels.
    private(set) lazy var approvals = FunesApprovals(environment: self)
    /// Approvals from the iPhone (task 5.6): what waits, the CloudKit doorbell and the phone's answers.
    private(set) lazy var phoneApprovals = CompanionApprovals(services: companionServices, disclosures: disclosures,
                                                              doorbell: CloudKitDoorbell())

    /// `~/Library/Application Support/FunesVault`. Debug builds honour FUNES_DATA_DIR (the
    /// launcher does too), so development never touches the real vault.
    static func defaultDataFolder() -> URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["FUNES_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Identifiers.supportFolderName, isDirectory: true)
    }

    init(dataFolder: URL = VaultEnvironment.defaultDataFolder(), retention: ActivityRetention = .funes,
         embeddings: Bool = true) throws {
        self.dataFolder = dataFolder
        try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        DataOperations.applyPendingRestore(dataFolder: dataFolder)
        store = try VaultStore.open(directory: dataFolder)
        activity = ActivityLog(dataFolder: dataFolder, retention: retention)
        keys = AgentKeyFileStore(dataFolder: dataFolder)
        agents = AgentService(store: store, issuer: BridgeKitKeyIssuer(), keys: keys, activity: activity)
        let indexer = embeddings ? Self.bundledIndexer(store: store) : nil
        self.indexer = indexer
        search = SearchService(store: store, indexer: indexer)
        disclosures = DisclosureService(store: store, retriever: search, activity: activity, pause: pause)
        suggestions = SuggestionService(store: store, activity: activity, pause: pause, disclosures: disclosures, splitting: splitting)
        captures = CaptureService(store: store, activity: activity)
        devices = DeviceService(store: store, activity: activity)
        imports = ImportService(store: store, activity: activity)
        profiles = ProfileService(store: store, activity: activity)
        if let indexer {
            try? indexer.loadIndex()
            observation = indexer.startObserving()
            Task.detached(priority: .utility) { _ = try? await indexer.embedPending() }
        }
    }

    var services: FunesServices {
        FunesServices(store: store, agents: agents, disclosures: disclosures, suggestions: suggestions, pause: pause,
                      activity: activity)
    }

    /// The vault services the iPhone companion uses (task 5.2).
    var companionServices: CompanionServices {
        CompanionServices(store: store, devices: devices, captures: captures, suggestions: suggestions, search: search,
                          agents: agents, activity: activity)
    }

    /// Whether vault search and agent retrieval use the bundled model (ADR-0016).
    var hasEmbeddings: Bool { indexer != nil }

    /// The bundled bge-small model (ADR-0016) when it's available; keyword search otherwise.
    /// The build copies it into Contents/Resources (scripts/embed_resources.sh); a Debug
    /// build without it also tries the converted copy in `~/Library/Caches/com.funesvault.dev`
    /// that scripts/fetch_embedding_model.sh makes.
    private static func bundledIndexer(store: VaultStore) -> EmbeddingIndexer? {
        var candidates = [Bundle.main.resourceURL?.appendingPathComponent("bge-small-en-v1.5")].compactMap { $0 }
        #if DEBUG
        candidates.append(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/com.funesvault.dev/bge-small-en-v1.5-5c38ec7"))
        #endif
        for folder in candidates {
            let model = folder.appendingPathComponent("bge-small-en-v1.5.mlmodelc")
            let vocab = folder.appendingPathComponent("vocab.txt")
            guard FileManager.default.fileExists(atPath: model.path) else { continue }
            do {
                return EmbeddingIndexer(store: store, provider: try BundledBGEEmbedder(compiledModelURL: model, vocabURL: vocab))
            } catch {
                logger.error("The embedding model didn't load; using keyword search")
            }
        }
        logger.notice("No embedding model; using keyword search")
        return nil
    }
}
