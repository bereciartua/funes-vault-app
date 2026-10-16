import Foundation
import FunesProtocol

/// Where the vault lives on disk (spec/architecture/storage.md).
public enum VaultLocation {
    /// `~/Library/Application Support/FunesVault/`.
    public static func supportDirectory(fileManager: FileManager = .default) throws -> URL {
        try fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appending(path: Identifiers.supportFolderName, directoryHint: .isDirectory)
    }
}
