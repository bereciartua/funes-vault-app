import FunesCore
import Observation
import SwiftUI

/// The setup checklist (FR-O-01): seed, review, add an agent, connect it.
@MainActor @Observable
final class ChecklistModel {
    private let preferences: Preferences
    var isVisible = false
    var showSeedQuestions = false

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func update(model: AppModel) {
        isVisible = false
    }
}

struct SetupChecklistCard: View {
    let model: AppModel
    var body: some View { EmptyView() }
}
