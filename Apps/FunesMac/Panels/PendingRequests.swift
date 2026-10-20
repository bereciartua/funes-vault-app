import FunesCore
import SwiftUI

/// Pending requests (FR-D-05): requests that waited past their panel, approvable for 15 minutes
/// from when they arrived. Review opens the same Share panel again.
struct PendingRequestsCard: View {
    let model: AppModel
    /// One agent's requests, on its page; every agent's otherwise (Activity).
    var agentID: UUID?

    private var requests: [PendingRequest] {
        agentID.map { id in model.pending.filter { $0.agentID == id } } ?? model.pending
    }

    var body: some View {
        Card(padding: 12) {
            HStack {
                Label(String(localized: "Pending requests"), systemImage: "hourglass").font(.headline)
                Spacer()
                Text(String(localized: "Agents get the answer when they check again.")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(requests) { request in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // On the agent's own page its icon and name would only repeat the header's.
                    if agentID == nil, let agent = model.agent(request.agentID) { AgentIcon(kind: agent.agentKind, size: 22) }
                    VStack(alignment: .leading, spacing: 1) {
                        if agentID == nil { Text(request.agentName).fontWeight(.medium) }
                        Text(request.summary(at: model.now)).foregroundStyle(.secondary).monospacedDigit()
                        if let task = request.task?.split(separator: "\n").first {
                            Text("“\(task)”").foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 0)
                    if request.status == .needsApproval { reviewButton(request) }
                    Button(String(localized: "Details")) { model.showActivity(.request(request.id)) }.buttonStyle(.link)
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
