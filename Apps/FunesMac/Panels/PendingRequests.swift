import FunesCore
import SwiftUI

/// Pending requests (FR-D-05): requests that waited past their panel, approvable for 15 minutes
/// from when they arrived. Review opens the same Share panel again.
struct PendingRequestsCard: View {
    let model: AppModel

    var body: some View {
        Card(padding: 12) {
            HStack {
                Label(String(localized: "Pending requests"), systemImage: "hourglass").font(.headline)
                Spacer()
                Text(String(localized: "Agents get the answer when they check again.")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.pending) { request in
                HStack(spacing: 10) {
                    if let agent = model.agent(request.agentID) { AgentIcon(kind: agent.agentKind, size: 22) }
                    Text(request.agentName).fontWeight(.medium)
                    if request.status == .approved {
                        Text(String(localized: "Approved, waiting for the agent to pick it up")).foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "\(request.minutesLeft(at: model.now)) min left")).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    if request.status == .needsApproval {
                        Button(String(localized: "Review…")) { model.openPendingRequest(request.id) }
                            .accessibilityLabel(String(localized: "Review \(request.agentName)'s request"))
                    }
                    Button(String(localized: "Details")) { model.showActivity(.request(request.id)) }.buttonStyle(.link)
                }
                .font(.callout)
            }
        }
    }
}
