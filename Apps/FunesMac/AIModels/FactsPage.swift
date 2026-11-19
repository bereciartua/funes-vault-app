import FunesCore
import FunesProtocol
import os
import SwiftUI

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "facts")

/// Features ▸ Facts (v0.10, working name; FR-F-01, model providers §4, 04-ux-mac.md ▸ Page: Facts): *Learn from
/// memories*, *Use in search and answers*, the model (only models that qualified), its status and disclosure, and Remove
/// Learned Facts…. Off by default. While no model has qualified (what ships until 13a.2's Gates step), both switches stay
/// off and the page says why.
///
/// The first backfill (FR-F-03): turning Learn from memories on the first time, with a model and memories, opens its
/// sheet (count and cost first); **Read Existing Memories…** opens it later, until it starts. While it runs the page shows
/// its progress with **Pause** / **Resume** (or **Review…** after a change of model or limit), and a wait for tomorrow's
/// cap when Facts jobs wait for it.
struct FactsPage: View {
    let model: AppModel
    @State private var confirmingRemoval = false
    @State private var removalFailed = false
    @State private var backfillSheet: FactsBackfillSheet.Mode?
    @State private var automaticSheet = false

    private var settings: ModelSettings { model.modelSettings }
    private var text: AIJobText { AIJobText(model: model) }

    private var removing: Bool { settings.factsRemoving }

    var body: some View {
        let available = settings.factsAvailable
        Form {
            Section {
                Toggle(String(localized: "Learn from memories"), isOn: Binding(get: { settings.factsLearn },
                                                                              set: { learn($0) }))
                    .disabled(removing || (!available && !settings.factsLearn))
                Text(String(localized: "Funes reads each new or changed memory to learn who the people in it are to you, and where you've worked and when."))
                    .font(.callout).foregroundStyle(.secondary)
                Toggle(String(localized: "Use in search and answers"), isOn: Binding(get: { settings.factsUse },
                                                                                    set: { settings.factsUse = $0 }))
                    .disabled(removing || (!available && !settings.factsUse))
                Text(String(localized: "Your searches find \"my sister\" when you ask about her by name, and answers say what they inferred."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                FactsModelRow(model: model)
                Text(text.factsStatus).font(.callout).foregroundStyle(.secondary)
                if let status = text.backfillStatus, let state = model.factsBackfill?.state {
                    HStack {
                        Text(status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if !settings.factsLearn {
                            EmptyView()
                        } else if state.changed {
                            Button(String(localized: "Review…")) { open(.review) }
                        } else {
                            Button(state.paused ? String(localized: "Resume") : String(localized: "Pause")) { pause(!state.paused) }
                        }
                    }
                }
                if let wait = text.factsCapStatus { Text(wait).font(.callout).foregroundStyle(.secondary) }
                if let disclosure = text.factsDisclosure { WarningLabel(text: disclosure, symbol: "arrow.up.forward.app") }
            }
            Section {
                HStack {
                    if model.factsBackfill == nil {
                        Button(String(localized: "Read Existing Memories…")) { open(.start) }
                            .disabled(removing || text.backfillUnavailable != nil)
                            .help(text.backfillUnavailable ?? "")
                    }
                    if removalFailed {
                        Text(String(localized: "Couldn't remove learned facts. Try again."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(removing ? String(localized: "Removing…") : String(localized: "Remove Learned Facts…")) {
                        confirmingRemoval = true
                    }
                    .disabled(removing)
                }
            }
        }
        .formStyle(.grouped)
        .aiSettingsRefresh(model)
        .alert(String(localized: "Remove everything Funes learned about you?"), isPresented: $confirmingRemoval) {
            Button(String(localized: "Remove"), role: .destructive) { remove() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(text.removeMessage)
        }
        .sheet(item: $backfillSheet) { mode in
            FactsBackfillSheet(model: model, mode: mode, automatic: automaticSheet,
                               shown: Binding(get: { backfillSheet != nil }, set: { if !$0 { backfillSheet = nil } }))
        }
    }

    /// Learn from memories: turned on the first time (no backfill yet) with a model, it offers the backfill (not when
    /// there's nothing to send).
    private func learn(_ on: Bool) {
        let first = on && !settings.factsLearn && model.factsBackfill == nil
        settings.factsLearn = on
        // The sheet counts archived memories too, and closes itself when there's nothing to send.
        if first, settings.factsProblem == nil { open(.start, automatic: true) }
    }

    private func open(_ mode: FactsBackfillSheet.Mode, automatic: Bool = false) {
        automaticSheet = automatic
        backfillSheet = mode
    }

    private func pause(_ paused: Bool) {
        let store = model.services.store
        Task {
            do { try await store.setFactsBackfillPaused(paused) } catch { logger.error("Pausing the facts backfill failed") }
            if !paused { model.processing.kick() }
            model.scheduleRefresh()
        }
    }

    /// `ModelSettings.removeLearnedFacts`: learning off, then everything inferred once no facts job is running.
    private func remove() {
        removalFailed = false
        let settings = settings, store = model.services.store, activity = model.services.activity
        Task {
            if await !settings.removeLearnedFacts(store: store, activity: activity) {
                logger.error("Removing learned facts failed")
                removalFailed = true
            }
        }
    }
}

/// Facts' Model row: the pop-up of qualified models and the chosen one's badge, or "None available".
struct FactsModelRow: View {
    let model: AppModel

    private var settings: ModelSettings { model.modelSettings }

    var body: some View {
        LabeledContent(String(localized: "Model")) {
            if settings.factsOffers.isEmpty {
                Text(String(localized: "None available")).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    FactsModelPicker(model: model)
                    if let locality = settings.factsLocality { LocalityPill(locality: locality) }
                }
            }
        }
    }
}

/// Facts' model pop-up (model providers §4): only offers, each a full model id under its account or plan, with why the
/// account can't run now; a model that qualified for part of what Facts learns says so; then the footer and Add a Model….
struct FactsModelPicker: View {
    let model: AppModel

    private var settings: ModelSettings { model.modelSettings }

    private enum Tag: Hashable {
        case offer(ModelChoice)
        case none
        case footer
        case addModel
    }

    var body: some View {
        let offers = settings.factsOffers
        let current = settings.factsChoice ?? settings.factsResolution.chosen?.choice
        let all = Set(FactsRegistry.bundled.callGroups.keys)
        let accounts = offers.map(\.account).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        Menu {
            Picker(selection: Binding<Tag>(get: { current.map(Tag.offer) ?? .none }, set: choose)) {
                if current == nil { Text(String(localized: "Choose a model")).tag(Tag.none) }
                ForEach(accounts, id: \.self) { account in
                    Section(header(account)) {
                        ForEach(offers.filter { $0.account == account }, id: \.self) { offer in
                            Text(offer.groups == all ? offer.model : String(localized: "\(offer.model) (part of what Facts learns)"))
                                .tag(Tag.offer(offer.choice))
                        }
                    }
                }
                if let chosen = settings.factsChoice, !offers.contains(where: { $0.choice == chosen }) {
                    Text(label(chosen)).tag(Tag.offer(chosen)).disabled(true)
                }
                Divider()
                Text(String(localized: "Only models that passed Funes's tests for Facts are listed.")).tag(Tag.footer).disabled(true)
                Text(String(localized: "Add a Model…")).tag(Tag.addModel)
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(current.map(label) ?? String(localized: "Choose a model"))
        }
        .fixedSize()
        .accessibilityLabel(String(localized: "Model: \(current.map(label) ?? String(localized: "Choose a model"))"))
    }

    private func header(_ account: String) -> String {
        let name = settings.name(account)
        return settings.problem(account: account).map { "\(name) — \(ProviderText.reason($0))" } ?? name
    }

    private func label(_ choice: ModelChoice) -> String {
        "\(settings.name(choice.account)) · \(choice.model ?? "")"
    }

    private func choose(_ tag: Tag) {
        switch tag {
        case let .offer(choice): settings.setFactsChoice(choice)
        case .addModel: model.showSettingsPane(.accounts)
        case .none, .footer: break
        }
    }
}

extension FactsBackfillSheet.Mode: Identifiable {
    var id: Self { self }
}
