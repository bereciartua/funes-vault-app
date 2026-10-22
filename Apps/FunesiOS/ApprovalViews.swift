import FunesPhone
import FunesProtocol
import SwiftUI
import UIKit

/// "Waiting for you" at the top of Capture: the requests on the Mac this iPhone can answer
/// (`approvals.list`), soonest deadline first. For a notification that never came or was dismissed.
struct ApprovalsSection: View {
    let model: PhoneModel

    var body: some View {
        let waiting = model.approvals.waiting
        if model.reachability.isConnected, !waiting.isEmpty {
            Section {
                ForEach(waiting) { item in
                    Button { model.open(ApprovalRef(id: item.id)) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: Self.symbol(item.kind))
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 28)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ApprovalWording.title(item)).foregroundStyle(.primary)
                                Text("Answer by \(item.expiresAt.formatted(date: .omitted, time: .shortened))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Waiting for you")
            } footer: {
                Text("Answer here or on your Mac. The first answer counts.")
            }
        }
    }

    static func symbol(_ kind: ApprovalKind) -> String {
        switch kind {
        case .share: "square.and.arrow.up"
        case .save: "tray.and.arrow.down"
        case .access: "key"
        }
    }
}

/// One request's panel (FR-iOS-12): the same contents as the Mac's Share, Save or access panel,
/// fetched fresh from the Mac, and answered once. Answers need the phone unlocked.
struct ApprovalPanelView: View {
    let model: PhoneModel
    let panel: ApprovalPanelModel
    /// Rows opened with Show All.
    @State private var expanded: Set<UUID> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // Leaving answers nothing: the request keeps waiting on the Mac.
                        Button(isOpen ? String(localized: "Later") : String(localized: "Done")) { dismiss() }
                    }
                }
        }
        .task { await panel.load() }
        .interactiveDismissDisabled(panel.phase == .sending)
    }

    private var isOpen: Bool { panel.phase == .ready || panel.phase == .sending }

    @ViewBuilder private var content: some View {
        switch panel.phase {
        case .loading:
            ProgressView("Asking your Mac…")
        case let .failed(error):
            ContentUnavailableView {
                Label(Self.unreachable(error) ? String(localized: "Mac not reachable") : String(localized: "Couldn't open this request"),
                      systemImage: Self.unreachable(error) ? "wifi.slash" : "exclamationmark.triangle")
            } description: {
                Text(Self.unreachable(error)
                    ? String(localized: "The request waits on your Mac. Answer it there, or try again when your Mac is reachable.")
                    : PhoneModel.vaultMessage(for: error))
            } actions: {
                Button("Try Again") { Task { await panel.load() } }
            }
        case let .closed(reason):
            ContentUnavailableView {
                Label(ApprovalWording.closed(reason), systemImage: Self.symbol(reason))
            } description: {
                Text(Self.explanation(reason))
            }
        case .ready, .sending:
            if let detail = panel.detail { form(detail) }
        }
    }

    private func form(_ detail: ApprovalDetail) -> some View {
        List {
            notices
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(heading(detail)).font(.title3.bold())
                    if let subtitle = subtitle(detail) {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.deadline(detail.expiresAt, now: context.date))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            switch detail.kind {
            case .share: if let share = detail.share { shareSections(detail, share) }
            case .save: if let save = detail.save { saveSections(detail, save) }
            case .access: if let task = detail.task, !task.isEmpty { agentSays([(String(localized: "Task"), "“\(task)”")]) }
            }
        }
        .safeAreaInset(edge: .bottom) { buttons(detail) }
        .disabled(panel.phase == .sending)
    }

    @ViewBuilder private var notices: some View {
        if panel.changed {
            Section {
                Label("This request changed on your Mac. Review it again.", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            }
        }
        if let failure = panel.answerFailure {
            Section {
                Label(Self.message(failure), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private func heading(_ detail: ApprovalDetail) -> String {
        if let save = detail.save { return ApprovalWording.saveHeading(save) }
        return ApprovalWording.title(detail)
    }

    private func subtitle(_ detail: ApprovalDetail) -> String? {
        if detail.save != nil { return ApprovalWording.saveSubtitle(agent: detail.agentName) }
        return detail.access.map(ApprovalWording.accessSubtitle)
    }

    // MARK: Share

    @ViewBuilder
    private func shareSections(_ detail: ApprovalDetail, _ share: SharePanel) -> some View {
        Section {
            Text(ApprovalWording.destination(agent: detail.agentName, share.destination))
        } header: {
            HStack(spacing: 6) {
                Text("Goes to")
                if share.destination.remote {
                    Text("Cloud")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .accessibilityLabel("Leaves your Mac")
                }
            }
        }
        agentSays(shareSays(detail, share))
        if let declared = share.declaredRetention, declared != .unknown {
            Section {
                LabeledContent("Your note", value: String(localized: "Keeps what it gets: \(ApprovalWording.retention(declared))"))
            }
        }
        Section {
            ForEach(panel.strongRows) { row in rowView(row) }
        } footer: {
            if panel.weakRows.isEmpty, let withheld = ApprovalWording.withheld(share.withheld) { Text(withheld) }
        }
        if !panel.weakRows.isEmpty {
            Section {
                ForEach(panel.weakRows) { row in rowView(row) }
            } header: {
                Text("Also matched, less closely")
            } footer: {
                if let withheld = ApprovalWording.withheld(share.withheld) { Text(withheld) }
            }
        }
    }

    /// What the agent said, labelled as such: shown as reported, never checked.
    private func shareSays(_ detail: ApprovalDetail, _ share: SharePanel) -> [(String, String)] {
        var says: [(String, String)] = []
        if let task = detail.task, !task.isEmpty { says.append((String(localized: "Task"), "“\(task)”")) }
        let keywords = share.keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !keywords.isEmpty { says.append((String(localized: "Looking for"), keywords.joined(separator: ", "))) }
        if let purpose = share.purpose, !purpose.isEmpty { says.append((String(localized: "Purpose"), "“\(purpose)”")) }
        says.append((String(localized: "Keeps what it gets"), ApprovalWording.retention(share.retention)))
        if !share.processors.isEmpty { says.append((String(localized: "Shared with"), share.processors.joined(separator: ", "))) }
        return says
    }

    @ViewBuilder
    private func agentSays(_ facts: [(String, String)]) -> some View {
        if !facts.isEmpty {
            Section("The agent says · not checked by Funes") {
                ForEach(facts, id: \.0) { label, value in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label).font(.caption).foregroundStyle(.secondary)
                        Text(value).textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// A memory with its checkbox and sensitivity badge, and its exact text: a preview, with all
    /// of it after Show All (the user approves the exact text).
    private func rowView(_ row: ApprovalRow) -> some View {
        let ticked = panel.isSelected(row.id)
        let open = expanded.contains(row.id)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button { panel.toggle(row.id) } label: {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(ticked ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(row.title)
            .accessibilityValue(ticked ? String(localized: "Ticked") : String(localized: "Not ticked"))
            .accessibilityAddTraits(.isToggle)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.title).fontWeight(.medium)
                    SensitivityBadge(sensitivity: row.sensitivity)
                }
                Text(open ? row.body : Self.preview(row.body))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if Self.preview(row.body) != row.body {
                    Button(open ? String(localized: "Show Less") : String(localized: "Show All")) {
                        if open { expanded.remove(row.id) } else { expanded.insert(row.id) }
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .accessibilityLabel(open ? String(localized: "Show less of \(row.title)") : String(localized: "Show all of \(row.title)"))
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Save

    @ViewBuilder
    private func saveSections(_ detail: ApprovalDetail, _ save: SavePanel) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(save.title).font(.headline)
                Text(save.body).textSelection(.enabled)
            }
            .padding(.vertical, 4)
            if let kind = save.kind { KindRow(kind: kind) }
            if !save.categories.isEmpty {
                LabeledContent("Category", value: save.categories.map(model.categories.name).formatted(.list(type: .and)))
            }
            if let sensitivity = save.sensitivity { LabeledContent("Sensitivity") { SensitivityBadge(sensitivity: sensitivity) } }
        }
        agentSays(saveSays(save))
    }

    private func saveSays(_ save: SavePanel) -> [(String, String)] {
        var says: [(String, String)] = []
        if let evidence = save.evidence, !evidence.isEmpty { says.append((String(localized: "Why"), evidence)) }
        if let purpose = save.purpose, !purpose.isEmpty { says.append((String(localized: "Purpose"), "“\(purpose)”")) }
        return says
    }

    // MARK: Buttons

    /// The default is drawn prominent and never has lasting effect: Share N, Save, or Allow Once.
    /// Always Allow is a link on its own line, never the default (UX review F1).
    private func buttons(_ detail: ApprovalDetail) -> some View {
        VStack(spacing: 10) {
            switch detail.kind {
            case .share:
                HStack(spacing: 12) {
                    Button("Deny", role: .destructive) { answer(.deny) }
                        .buttonStyle(.bordered)
                    Button("Share \(panel.selectedCount)") { answer(.share) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!panel.canShare)
                }
            case .save:
                HStack(spacing: 12) {
                    Button("Discard", role: .destructive) { answer(.discard) }
                        .buttonStyle(.bordered)
                    Button("Save") { answer(.save) }
                        .buttonStyle(.borderedProminent)
                }
            case .access:
                if let access = detail.access {
                    HStack(spacing: 12) {
                        Button("Not Now") { answer(.notNow) }
                            .buttonStyle(.bordered)
                        if access.allowsOnce {
                            Button("Allow Once") { answer(.allowOnce) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    Button(ApprovalWording.alwaysAllow(agent: detail.agentName, operation: access.operation, category: access.categoryName)) {
                        answer(.alwaysAllow)
                    }
                    .font(.footnote)
                }
            }
            if panel.phase == .sending { ProgressView() }
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .padding()
        .background(.bar)
        .disabled(panel.phase != .ready)
    }

    private func answer(_ choice: ApprovalChoice) {
        Task {
            await panel.answer(choice)
            if case .closed(.answered) = panel.phase {
                try? await Task.sleep(for: .seconds(1))
                dismiss()
            }
        }
    }

    // MARK: Words

    static func unreachable(_ error: CompanionClientError) -> Bool {
        if case .unreachable = error { return true }
        return false
    }

    static func message(_ failure: ApprovalPanelModel.AnswerFailure) -> String {
        switch failure {
        case .locked:
            String(localized: "Unlock your iPhone to answer.")
        case .call(.unreachable):
            String(localized: "Mac not reachable. Your answer didn't get through: try again, or answer on your Mac.")
        case let .call(error):
            PhoneModel.vaultMessage(for: error)
        }
    }

    static func symbol(_ reason: ApprovalPanelModel.Closed) -> String {
        switch reason {
        case .answered: "checkmark.circle"
        case .answeredOnMac, .alreadyAnswered: "macbook"
        case .expired: "clock.badge.xmark"
        case .gone: "tray"
        }
    }

    static func explanation(_ reason: ApprovalPanelModel.Closed) -> String {
        switch reason {
        case .answered: String(localized: "Your Mac has your answer.")
        case .answeredOnMac: String(localized: "Nothing more to do here.")
        case .alreadyAnswered: String(localized: "Your answer may have reached your Mac before the connection dropped. Activity on your Mac shows what happened.")
        case .expired: String(localized: "Requests wait 15 minutes. The agent can ask again.")
        case .gone: String(localized: "It's no longer waiting on your Mac.")
        }
    }

    /// "Answer within 14:59", then "Time's up".
    static func deadline(_ expiresAt: Date, now: Date) -> String {
        let seconds = Int(expiresAt.timeIntervalSince(now).rounded(.up))
        guard seconds > 0 else { return String(localized: "Time's up on your Mac") }
        return String(localized: "Answer within \(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))")
    }

    /// The first 3 lines, at most 160 characters, cut at a word: BridgeUI's `PanelText.preview`.
    static func preview(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var shown = lines.prefix(3).joined(separator: "\n")
        guard lines.count > 3 || shown.count > 160 else { return text }
        if shown.count > 160 {
            shown = String(shown.prefix(160))
            if let space = shown.lastIndex(where: { $0 == " " || $0 == "\n" || $0 == "," }),
               shown.distance(from: shown.startIndex, to: space) > 80 {
                shown = String(shown[..<space])
            }
        }
        return shown.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

/// Settings ▸ Approvals: "Approve requests on this iPhone" (the same switch as Settings ▸ iPhone
/// on the Mac), and why notifications might not come.
struct ApprovalSettingsSection: View {
    let model: PhoneModel

    var body: some View {
        let approvals = model.approvalSettings
        Section {
            Toggle("Approve requests on this iPhone", isOn: Binding(
                get: { approvals.settings?.enabled ?? false },
                set: { enabled in Task { await approvals.setEnabled(enabled) } }))
                .disabled(approvals.settings == nil || approvals.saving || !model.reachability.isConnected)
            ForEach(lines, id: \.self) { line in
                Label(line, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            #if DEBUG
            if let error = approvals.subscriptionError {
                Text(error).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            #endif
            if approvals.settings?.enabled == true, model.notificationsAllowed == false {
                Button("Open Notification Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        } header: {
            Text("Approvals")
        } footer: {
            if approvals.settings == nil {
                Text("Connect to your Mac to change this.")
            } else {
                Text("When an agent asks to share or save memories, this iPhone gets a notification and can answer, as your Mac can. The notification names the agent, never your memories.")
            }
        }
    }

    /// Why a request might not reach this iPhone as a notification, most fixable first.
    private var lines: [String] {
        let approvals = model.approvalSettings
        var lines: [String] = []
        if let failure = approvals.failure { lines.append(PhoneModel.vaultMessage(for: failure)) }
        guard let settings = approvals.settings, settings.enabled else { return lines }
        if model.notificationsAllowed == false {
            lines.append(String(localized: "Notifications are off for Funes Vault on this iPhone."))
        }
        switch approvals.subscription {
        case .noICloud:
            lines.append(String(localized: "Sign in to iCloud on this iPhone, with the same Apple Account as your Mac, to get notifications."))
        case .failed:
            lines.append(String(localized: "Couldn't set up notifications with iCloud. Funes tries again when it next opens."))
        case .unknown, .off, .subscribed:
            break
        }
        switch settings.doorbell {
        case .available: break
        case .noAccount: lines.append(String(localized: "Your Mac isn't signed in to iCloud, so it can't notify this iPhone. Requests still show here when you open Funes."))
        case .restricted: lines.append(String(localized: "iCloud is restricted on your Mac, so it can't notify this iPhone. Requests still show here when you open Funes."))
        case .unsupported: lines.append(String(localized: "This build of Funes on your Mac can't notify iPhones. Requests still show here when you open Funes."))
        }
        return lines
    }
}
