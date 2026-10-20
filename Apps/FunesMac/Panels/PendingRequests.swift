import FunesCore
import SwiftUI

/// Pending requests (FR-D-05): requests that waited past their panel, approvable for 15 minutes
/// from when they arrived. Review opens the same Share panel again.
struct PendingRequestsCard: View {
    let model: AppModel
    /// The Agents list's version: no Details link and no caption, for a narrow column.
    var compact = false

    var body: some View {
        Card(padding: 12) {
            HStack {
                Label(String(localized: "Pending requests"), systemImage: "hourglass").font(.headline)
                Spacer()
                if !compact {
                    Text(String(localized: "Agents get the answer when they check again.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(model.pending) { request in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let agent = model.agent(request.agentID) { AgentIcon(kind: agent.agentKind, size: 22) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(request.agentName).fontWeight(.medium)
                        Text(request.summary(at: model.now)).foregroundStyle(.secondary).monospacedDigit()
                        if let task = request.task?.split(separator: "\n").first {
                            Text("“\(task)”").foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        }
                        // In the narrow list, Review… goes under the text so neither is squeezed.
                        if compact, request.status == .needsApproval {
                            reviewButton(request).padding(.top, 4)
                        }
                    }
                    Spacer(minLength: 0)
                    if !compact {
                        if request.status == .needsApproval { reviewButton(request) }
                        Button(String(localized: "Details")) { model.showActivity(.request(request.id)) }.buttonStyle(.link)
                    }
                }
                .font(.callout)
            }
        }
    }

    private func reviewButton(_ request: PendingRequest) -> some View {
        Button(String(localized: "Review…")) { model.openPendingRequest(request.id) }
            .accessibilityLabel(String(localized: "Review \(request.agentName)'s request"))
    }
}
