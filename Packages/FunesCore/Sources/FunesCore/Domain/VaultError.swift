import Foundation
import FunesProtocol

/// Errors from the vault's store and services. Messages never contain memory text, task text or
/// keys: only field names, keys, ids and pattern types.
public enum VaultError: Error, Sendable, Equatable {
    /// A length, count or value is outside its limit. `field` names the input.
    case invalidInput(field: String)
    case unknownCategory(String)
    /// The secret scanner matched; the pattern types found, never the text.
    case secretLikeContent([SecretPattern])
    case notFound
    /// A memory needs at least one category.
    case noCategories
    case builtinCategory
    case categoryExists
    /// Deleting the category would leave memories without a category; choose a replacement.
    case categoryInUse
    /// The category is the only allowed category of these agents; deleting it would widen their access.
    case onlyAllowedCategory(agentIDs: [UUID])
    case nameTaken
    /// The vault was written by a newer version of Funes: refuse to open it ("Update Funes").
    case newerSchema
    /// A file or folder of the vault isn't safe to open (owner, mode, symlink).
    case unsafeFile(String)
    /// The operation doesn't apply in the object's current state.
    case invalidState
    /// The approval panel's snapshot is stale (T22): "This request changed; review again".
    case snapshotChanged
    /// No valid key, removed agent or revoked device: HTTP 401 at the transport.
    case unauthenticated
    /// The agent's access changed since the editor read it (e.g. Always Allow from a panel): "This
    /// agent's access changed; review again." Nothing was saved.
    case revisionChanged
    /// A memory changed since the caller read it (the iPhone sends the version it saw): "Changed
    /// on your Mac, reload?". Nothing was saved.
    case versionConflict
    /// A memory the suggestion refers to changed, or was archived or deleted, since it was
    /// suggested: "Changed since this was suggested". Nothing was saved.
    case targetChanged
    /// The suggestion's action can't be applied this way: a conflict without an answer, or an
    /// answer meant for another action. Nothing was saved.
    case unsupportedAction
    /// New memories processing hasn't finished with the suggestion: it shows "Processing…" and
    /// can't be applied until the result replaces it (memory processing §5.2). Nothing was saved.
    case processing
    /// Later automatic changes depend on this one: "Undo this and N later changes".
    case undoNeedsLater(Int)
    /// A memory it changed was changed again since by someone other than Funes, or the change is
    /// gone, expired or already undone. Nothing was undone.
    case undoNotPossible
}
