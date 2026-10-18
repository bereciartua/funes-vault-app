import BridgeKitCore
import Foundation
import FunesCore
import FunesProtocol

/// BridgeKitCore's key issue and digest for FunesCore's `AgentService`: 32 bytes from the
/// CSPRNG, `fns_mcp_v1_` + 64 lowercase hex, SHA-256 stored.
public struct BridgeKitKeyIssuer: AgentKeyIssuer {
    public init() {}

    public func issue() throws -> IssuedKey {
        let key = AgentKey.issue(prefix: Identifiers.mcpKeyPrefix)
        return IssuedKey(plaintext: key, digest: AgentKey.digest(key))
    }

    public func issueRemote() throws -> IssuedKey {
        let key = AgentKey.issue(prefix: Identifiers.remoteKeyPrefix)
        return IssuedKey(plaintext: key, digest: AgentKey.digest(key))
    }

    public func digest(of key: String) -> Data { AgentKey.digest(key) }
}

/// `agent-keys/<agentId>.key`, and the remote token in `agent-keys/<agentId>.remote.key`, in the
/// data folder: 0600 files in a 0700 folder, written atomically, never through a symlink
/// (BridgeKitCore's `SecretFileStore`).
public final class AgentKeyFileStore: AgentKeyStore {
    public let files: AgentKeyFiles
    public let remoteFiles: AgentKeyFiles

    public init(dataFolder: URL) {
        let store = SecretFileStore(parent: dataFolder, folderName: FunesMCPConfiguration.keyFolderName)
        files = AgentKeyFiles(store: store, keyPrefix: Identifiers.mcpKeyPrefix, kind: FunesMCPConfiguration.keyFile)
        remoteFiles = AgentKeyFiles(store: store, keyPrefix: Identifiers.remoteKeyPrefix,
                                    kind: FunesMCPConfiguration.remoteKeyFile)
    }

    public func writeRemote(_ key: String, agentID: UUID) throws {
        if case .failure(let error) = remoteFiles.save(agentID: agentID.uuidString.lowercased(), key: key) { throw error }
    }

    public func deleteRemote(agentID: UUID) throws {
        if case .failure(let error) = remoteFiles.remove(agentID: agentID.uuidString.lowercased()) { throw error }
    }

    /// The remote token's file, for Copy Remote Token…
    public func remoteURL(agentID: UUID) -> URL? { remoteFiles.url(agentID: agentID.uuidString.lowercased()) }

    public func write(_ key: String, agentID: UUID) throws {
        if case .failure(let error) = files.save(agentID: agentID.uuidString.lowercased(), key: key) { throw error }
    }

    public func delete(agentID: UUID) throws {
        if case .failure(let error) = files.remove(agentID: agentID.uuidString.lowercased()) { throw error }
    }

    public func url(agentID: UUID) -> URL? { files.url(agentID: agentID.uuidString.lowercased()) }
}

extension CredentialFileError: @retroactive LocalizedError {
    public var errorDescription: String? { "agent key file: \(rawValue)" }
}
