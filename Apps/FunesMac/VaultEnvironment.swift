import BridgeUI
import Foundation
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
    private var indexer: EmbeddingIndexer?
    private var observation: AnyObject?

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

    init(dataFolder: URL = VaultEnvironment.defaultDataFolder()) throws {
        self.dataFolder = dataFolder
        try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        store = try VaultStore.open(directory: dataFolder)
        activity = ActivityLog(dataFolder: dataFolder)
        keys = AgentKeyFileStore(dataFolder: dataFolder)
        agents = AgentService(store: store, issuer: BridgeKitKeyIssuer(), keys: keys, activity: activity)
        let indexer = Self.bundledIndexer(store: store)
        self.indexer = indexer
        search = SearchService(store: store, indexer: indexer)
        disclosures = DisclosureService(store: store, retriever: search, activity: activity, pause: pause)
        suggestions = SuggestionService(store: store, activity: activity, pause: pause, disclosures: disclosures)
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

    /// The bundled bge-small model (ADR-0016) when it's available; keyword search otherwise.
    /// Until the model ships inside the app (Phase 4), development builds use the converted copy
    /// in `~/Library/Caches/com.funesvault.dev` that scripts/fetch_embedding_model.sh makes.
    private static func bundledIndexer(store: VaultStore) -> EmbeddingIndexer? {
        let cache = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/com.funesvault.dev/bge-small-en-v1.5-5c38ec7")
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("bge-small-en-v1.5"), cache].compactMap { $0 }
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
