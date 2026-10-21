/// Identifiers that are final from the first public release
/// (spec/plans/project-setup.md). Changing one breaks Sparkle updates,
/// Keychain items, the data folder or the App Store record.
public enum Identifiers {
    public static let macBundleID = "com.funesvault.mac"
    public static let iOSBundleID = "com.funesvault.ios"
    public static let iOSShareExtensionBundleID = "com.funesvault.ios.share"
    public static let iOSIntentsBundleID = "com.funesvault.ios.intents"
    /// The notification service extension that words approval alerts (task 5.6, ADR-0019).
    public static let iOSNotificationsBundleID = "com.funesvault.ios.notifications"
    public static let appGroup = "group.com.funesvault"

    /// Folder name under `~/Library/Application Support/`.
    public static let supportFolderName = "FunesVault"

    public static let macLoggerSubsystem = "com.funesvault.mac"
    public static let iOSLoggerSubsystem = "com.funesvault.ios"

    /// Keychain service for model provider API keys.
    public static let providerKeychainService = "com.funesvault.provider"
    /// Keychain service for the Mac's companion identity (its id and P-256 keys; companion protocol §1).
    public static let companionKeychainService = "com.funesvault.companion"
    /// Keychain service on the iPhone for the device keys and the pairing record (companion
    /// protocol §1), in the access group the app and its extensions share.
    public static let phoneKeychainService = "com.funesvault.ios.companion"
    /// That access group without its team prefix: `<team>.com.funesvault.shared`.
    public static let phoneKeychainGroupSuffix = "com.funesvault.shared"

    /// MCP server key in agent configs, the launcher name and the agent key prefix.
    public static let mcpServerKey = "funes"
    public static let mcpLauncherName = "funes-mcp"
    public static let mcpKeyPrefix = "fns_mcp_v1_"

    /// Remote Access (ADR-0018): an agent's remote token, and the OAuth access token, refresh
    /// token and set-up client secret cloud apps get. Each is the prefix plus 64 lowercase hex.
    public static let remoteKeyPrefix = "fns_mcpr_v1_"
    public static let oauthAccessPrefix = "fns_oat_v1_"
    public static let oauthRefreshPrefix = "fns_ort_v1_"
    public static let oauthClientSecretPrefix = "fns_ocs_v1_"
    /// The OAuth scope cloud apps are granted.
    public static let oauthScope = "memory"

    public static let bonjourServiceType = "_funes._tcp"
    public static let iOSDeliveryTaskID = "com.funesvault.ios.deliver"
}
