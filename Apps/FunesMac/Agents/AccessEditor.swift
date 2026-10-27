import FunesCore
import FunesProtocol
import SwiftUI

/// The access editor (FR-A-03, FR-A-10, FR-A-12, access-policy.md): operations, the sensitivity
/// ceiling, the category allow/deny table, ask-before switches, expiry, and asking for more.
/// Saving bumps the agent's revision, which cancels its pending approvals.
struct AccessEditor: View {
    let model: AppModel
    let agent: Agent
    /// The draft knows the agent it was built from (FunesCore `AccessDraft`): an untouched one
    /// follows changes made elsewhere; an edited one can't overwrite them (PR #3 review 4304236144).
    @State private var draft: AccessDraft

    init(model: AppModel, agent: Agent) {
        self.model = model
        self.agent = agent
        _draft = State(initialValue: AccessDraft(agent))
    }

    private var access: Access {
        get { draft.access }
        nonmutating set { draft.access = newValue }
    }
    @State private var error: String?
    @State private var saved = false

    private var dirty: Bool { draft.isEdited }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                operations
                ceiling
                categories
                asking
                aboutYou
                expiry
                more
                footer
            }
            .padding(20)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: agent) { _, agent in draft = draft.refreshed(from: agent) }
    }

    // MARK: Sections

    private var operations: some View {
        Card {
            Text(String(localized: "What it can do")).font(.headline)
            operation(.read, String(localized: "Read"), String(localized: "Ask for memories that match its task. Only memories this page allows are ever offered."))
            operation(.suggest, String(localized: "Suggest"), String(localized: "Propose new memories or corrections. They wait in your Inbox."))
            operation(.write, String(localized: "Write"), String(localized: "Save new memories, within the limits below. Corrections still wait in your Inbox."))
        }
    }

    private func operation(_ op: AccessOperation, _ title: String, _ detail: String) -> some View {
        SwitchRow(title: title, detail: detail, isOn: Binding(get: { access.operations.contains(op) }, set: { on in
            if on { access.operations.insert(op) } else { access.operations.remove(op) }
        }))
    }

    private var ceiling: some View {
        Card {
            Text(String(localized: "Maximum sensitivity")).font(.headline)
            Slider(value: Binding(get: { Double(access.maxSensitivity.rawValue) },
                                  set: { access.maxSensitivity = Sensitivity(rawValue: Int($0.rounded())) ?? .public }),
                   in: 0...5, step: 1) {
                Text(String(localized: "Maximum sensitivity"))
            } minimumValueLabel: {
                Text(Sensitivity.public.title).font(.caption)
            } maximumValueLabel: {
                Text(Sensitivity.secret.title).font(.caption)
            }
            .labelsHidden()
            .accessibilityValue(access.maxSensitivity.title)
            HStack(spacing: 6) {
                SensitivityBadge(sensitivity: access.maxSensitivity)
                Text(String(localized: "and below: \(access.maxSensitivity.explanation)"))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if access.maxSensitivity >= .sensitive {
                WarningLabel(text: String(localized: "\(agent.name) can be offered personal memories. Keep Ask before sharing on."))
            }
        }
    }

    private var categories: some View {
        Card {
            Text(String(localized: "Categories")).font(.headline)
            Text(access.allowedCategoryKeys.isEmpty
                 ? String(localized: "Empty allow list means all categories. Deny always wins.")
                 : String(localized: "Only allowed categories can be shared. Deny always wins."))
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(model.categories) { category in
                    GridRow {
                        Text(category.name)
                        Picker(String(localized: "\(category.name) access"), selection: Binding(
                            get: { mode(category.key) }, set: { setMode($0, for: category.key) })) {
                            Text(String(localized: "Allow")).tag(CategoryMode.allow)
                            Text("—").tag(CategoryMode.none)
                            Text(String(localized: "Deny")).tag(CategoryMode.deny)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel(String(localized: "\(category.name) access"))
                    }
                }
            }
        }
    }

    private var asking: some View {
        Card {
            SwitchRow(title: String(localized: "Ask before sharing"),
                      detail: String(localized: "A panel shows exactly what would be shared, and nothing goes until you choose."),
                      isOn: $draft.access.askBeforeSharing)
            if !access.askBeforeSharing {
                WarningLabel(text: String(localized: "\(agent.name) will get matching memories it's allowed to read without asking you. You'll see each share in Activity."))
            }
            if access.operations.contains(.write) {
                SwitchRow(title: String(localized: "Ask before saving"),
                          detail: String(localized: "Off: it saves memories directly. On: they wait in your Inbox."),
                          isOn: $draft.access.askBeforeSaving)
            }
        }
    }

    /// The profile fields its answers carry (ADR-0026, access policy §3.10). Saved with the rest
    /// of the tab, so changing them bumps the revision like any access change.
    private var aboutYou: some View {
        ProfileFieldsCard(model: model, agentName: agent.name, fields: $draft.access.profileFields,
                          reads: access.operations.contains(.read))
    }

    private var expiry: some View {
        Card {
            HStack {
                Text(String(localized: "Access expires")).font(.headline)
                Spacer()
                Picker(String(localized: "Access expires"), selection: Binding(get: { access.expiresAt != nil }, set: { on in
                    access.expiresAt = on ? (access.expiresAt ?? Calendar.current.date(byAdding: .month, value: 1, to: Date())) : nil
                })) {
                    Text(String(localized: "Never")).tag(false)
                    Text(String(localized: "On a date")).tag(true)
                }
                .labelsHidden()
                .fixedSize()
                if let date = access.expiresAt {
                    DatePicker(String(localized: "Expiry date"), selection: Binding(get: { date }, set: { access.expiresAt = $0 }),
                               displayedComponents: .date)
                        .labelsHidden()
                }
            }
        }
    }

    private var more: some View {
        Card {
            SwitchRow(title: String(localized: "Let it ask for more access"),
                      detail: String(localized: "When a request is refused only because a category isn't allowed, Funes asks you: Not Now, Allow Once or Always Allow. Never for the sensitivity limit or denied categories."),
                      isOn: $draft.asksForAccess)
            HStack {
                Text(String(localized: "Keeps what it gets"))
                Spacer()
                Picker(String(localized: "Keeps what it gets"), selection: $draft.retention) {
                    ForEach(Retention.allCases, id: \.self) { Text(AgentText.retention($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text(String(localized: "Your note on how this agent keeps data. Its Share panels show it next to what the agent says; it doesn't change what's shared."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if draft.isStale {
                VStack(alignment: .leading, spacing: 4) {
                    WarningLabel(text: String(localized: "\(agent.name)'s access changed while you were editing (for example, Always Allow from a panel). Review it again before saving."))
                    Button(String(localized: "Show the Current Access")) { reset() }.buttonStyle(.link)
                }
            } else if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            } else if dirty, model.pending.contains(where: { $0.agentID == agent.id }) {
                Text(String(localized: "Saving cancels \(agent.name)'s pending requests; it can ask again."))
                    .font(.callout).foregroundStyle(.secondary)
            } else if saved {
                Text(String(localized: "Saved")).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "Revert"), action: reset).disabled(!dirty)
            Button(String(localized: "Save")) { save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!dirty || draft.isStale)
        }
    }

    // MARK: Categories

    enum CategoryMode: Hashable { case allow, none, deny }

    private func mode(_ key: String) -> CategoryMode {
        if access.deniedCategoryKeys.contains(key) { return .deny }
        if access.allowedCategoryKeys.contains(key) { return .allow }
        return .none
    }

    private func setMode(_ mode: CategoryMode, for key: String) {
        access.allowedCategoryKeys.remove(key)
        access.deniedCategoryKeys.remove(key)
        switch mode {
        case .allow: access.allowedCategoryKeys.insert(key)
        case .deny: access.deniedCategoryKeys.insert(key)
        case .none: break
        }
    }

    // MARK: Actions

    private func reset() {
        draft = AccessDraft(agent)
        error = nil
    }

    private func save() {
        let draft = draft
        Task {
            do {
                self.draft = try await draft.save(with: model.services.agents, now: Date())
                error = nil
                saved = true
                await model.refresh()
            } catch VaultError.revisionChanged {
                self.error = String(localized: "\(agent.name)'s access changed while you were editing. Nothing was saved: review it again.")
                if let current = try? await model.services.agents.agent(id: agent.id) {
                    self.draft = self.draft.refreshed(from: current)
                }
            } catch {
                self.error = ErrorText.message(error)
            }
        }
    }
}

/// The Access tab's About you card: a checkbox per profile field, each with its value dimmed.
/// Disabled without Read, which gets nothing (access policy §3.10 rule 1).
struct ProfileFieldsCard: View {
    let model: AppModel
    let agentName: String
    @Binding var fields: Set<ProfileField>
    let reads: Bool

    var body: some View {
        Card {
            Text(String(localized: "About you")).font(.headline)
            Text(String(localized: "Sent with every answer to \(agentName)'s requests, without asking. Edit them in Settings ▸ About You."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(ProfileField.allCases, id: \.self) { field in
                let title = ProfileText.title(field)
                let value = ProfileText.value(field, in: model.profile)
                Toggle(isOn: Binding(get: { fields.contains(field) }, set: { on in
                    if on { fields.insert(field) } else { fields.remove(field) }
                })) {
                    HStack(spacing: 6) {
                        Text(title)
                        Text("· \(value)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!reads)
                .accessibilityLabel(String(localized: "Send \(title): \(value)"))
            }
            if !reads {
                Text(String(localized: "Needs Read.")).font(.callout).foregroundStyle(.secondary)
            }
            Button(String(localized: "About You…")) { model.openSettings(.aboutYou) }
                .buttonStyle(.link)
        }
    }
}

/// A title and explanation on the left, the switch on the right.
struct SwitchRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
    }
}
