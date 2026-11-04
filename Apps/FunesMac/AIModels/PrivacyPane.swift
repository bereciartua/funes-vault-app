import FunesCore
import FunesProtocol
import SwiftUI

/// Settings ▸ AI ▸ Privacy & Limits (04-ux-mac.md, ADR-0030 §5, ADR-0022): the cloud limit with its
/// one-time confirmation above Internal, cloud requests per day with today's count, and what each
/// AI feature sends, from the same facts as the job pages' disclosure lines.
struct PrivacyPane: View {
    let model: AppModel
    /// A cloud limit above Internal waiting for its confirmation.
    @State private var confirming: CloudLimit?
    @State private var today: CloudRequestCap.Day?

    private var settings: ModelSettings { model.modelSettings }
    private var text: AIJobText { AIJobText(model: model) }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Send memories to cloud models up to"), selection: Binding(get: { settings.cloudLimit },
                                                                                                   set: { choose($0) })) {
                    ForEach([Sensitivity.public, .low, .internal, .sensitive, .restricted], id: \.self) { level in
                        Text(level == .internal ? String(localized: "Internal (recommended)") : level.title).tag(CloudLimit.upTo(level))
                    }
                    Text(String(localized: "Everything, including Secret")).tag(CloudLimit.upTo(.secret))
                    Divider()
                    Text(String(localized: "Nothing")).tag(CloudLimit.never)
                }
                Text(String(localized: "Applies to every cloud provider and every task. Text is checked on this Mac first, and anything that looks like a secret is never sent, whatever the limit."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Stepper(value: Binding(get: { settings.dailyCap }, set: { settings.dailyCap = $0 }), in: 10...10_000, step: 50) {
                    LabeledContent(String(localized: "Cloud requests per day"), value: settings.dailyCap.formatted())
                }
                Text(capLine).font(.callout).foregroundStyle(.secondary)
            }
            Section(String(localized: "What AI features send")) {
                let lines = text.sendFacts.map(text.sendLine)
                if lines.isEmpty {
                    Text(String(localized: "AI features send nothing off this Mac.")).font(.callout)
                }
                ForEach(lines, id: \.text) { line in
                    Label {
                        Text(line.text).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: line.leaves ? "arrow.up.forward.app" : "house")
                            .foregroundStyle(line.leaves ? Palette.warning : .secondary)
                    }
                    .font(.callout)
                }
                Text(String(localized: "Agents, Remote Access and your iPhone are in their own panes."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: model.activityGeneration) {
            today = try? await settings.cap(store: model.services.store, activity: model.services.activity).today(now: Date())
        }
        .aiSettingsRefresh(model)
        .alert(String(localized: "Send more sensitive memories to cloud models?"),
               isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { limit in
            Button(String(localized: "Send Up to \(CloudLimitText.title(limit))")) { settings.cloudLimit = limit }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { limit in
            Text(String(localized: "Memories up to \(CloudLimitText.title(limit)) can then be sent to \(cloudNames ?? String(localized: "the cloud providers you choose")). They can include health, money, family or legal matters. Funes still never sends anything that looks like a secret."))
        }
    }

    /// The cloud accounts the jobs use now: "Claude (Claude Code) and Anthropic".
    private var cloudNames: String? {
        var names: [String] = []
        for fact in text.sendFacts {
            guard case let .account(account, _, locality) = fact.destination, !locality.isLocal else { continue }
            let name = settings.name(account)
            if !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? nil : names.formatted(.list(type: .and))
    }

    /// Above Internal asks once to confirm, naming the provider (ADR-0022).
    private func choose(_ limit: CloudLimit) {
        if limit.needsConfirmation, !settings.cloudLimit.needsConfirmation {
            confirming = limit
        } else {
            settings.cloudLimit = limit
        }
    }

    /// "Today: 12 of 300 (agents 3 of 120)." (ADR-0022)
    private var capLine: String {
        let cap = settings.dailyCap
        let agents = Int((Double(cap) * CloudRequestCap.agentShare).rounded(.down))
        let total = today?.total ?? 0, byAgents = today?.agents ?? 0
        return String(localized: "Today: \(total) of \(cap), agents \(byAgents) of \(agents). Shared by every task that uses a cloud model; on-device models and embeddings don't count. At the limit, new captures are classified on this Mac until tomorrow.")
    }
}
