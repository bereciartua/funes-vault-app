import SwiftUI

// Sections and settings panes that later Phase 3 tasks fill in.

struct ModelSettingsPane: View { let model: AppModel; var body: some View { Placeholder(title: SettingsTab.models.title) } }
struct MCPSettings: View { let model: AppModel; var body: some View { Placeholder(title: SettingsTab.mcp.title) } }
struct DataSettings: View { let model: AppModel; var body: some View { Placeholder(title: SettingsTab.data.title) } }
struct UpdateSettings: View { let model: AppModel; var body: some View { Placeholder(title: SettingsTab.updates.title) } }
struct AdvancedSettings: View { let model: AppModel; var body: some View { Placeholder(title: SettingsTab.advanced.title) } }

private struct Placeholder: View {
    let title: String
    var body: some View { ContentUnavailableView(title, systemImage: "hammer") }
}
