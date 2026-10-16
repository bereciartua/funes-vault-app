/// Identifiers that are final from the first public release
/// (spec/plans/project-setup.md). Changing one breaks Sparkle updates,
/// Keychain items, the data folder or the App Store record.
public enum Identifiers {
    public static let macBundleID = "com.funesvault.mac"
    public static let iOSBundleID = "com.funesvault.ios"
    public static let appGroup = "group.com.funesvault"

    /// Folder name under `~/Library/Application Support/`.
    public static let supportFolderName = "FunesVault"

    public static let macLoggerSubsystem = "com.funesvault.mac"
    public static let iOSLoggerSubsystem = "com.funesvault.ios"

    /// Keychain service for model provider API keys.
    public static let providerKeychainService = "com.funesvault.provider"

    /// MCP server key in agent configs, the launcher name and the agent key prefix.
    public static let mcpServerKey = "funes"
    public static let mcpLauncherName = "funes-mcp"
    public static let mcpKeyPrefix = "fns_mcp_v1_"

    public static let bonjourServiceType = "_funes._tcp"
    public static let iOSDeliveryTaskID = "com.funesvault.ios.deliver"
}
