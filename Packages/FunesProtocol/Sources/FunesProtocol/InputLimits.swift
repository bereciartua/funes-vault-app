/// Length and count limits on everything a user, agent or device can send
/// (spec/domain/domain-model.md, spec/architecture/mcp-server.md §6).
///
/// Lengths count Unicode scalars, as SQLite's `length()` does for the schema's CHECK constraints,
/// so a text that passes here always fits the database. Use `InputLimits.length(of:)`.
public enum InputLimits {
    public static let title = 1...180
    public static let body = 1...10_000
    public static let task = 1...1_000
    public static let keywordCount = 20
    public static let keywordLength = 1...60
    public static let purpose = 160
    public static let evidence = 2_000
    /// Categories on a memory or suggestion.
    public static let memoryCategories = 12
    /// Categories narrowing a `request_memory`.
    public static let requestCategories = 24
    public static let processorCount = 12
    public static let processorLength = 120
    public static let maxTokens = 100...8_000
    public static let defaultMaxTokens = 1_200
    /// Serialized caller metadata on `suggest_memory`, in bytes.
    public static let callerMetadataBytes = 4_096
    /// Titles proposed by classification.
    public static let proposedTitle = 80

    /// The length these limits measure: Unicode scalars.
    public static func length(of text: String) -> Int { text.unicodeScalars.count }
}
