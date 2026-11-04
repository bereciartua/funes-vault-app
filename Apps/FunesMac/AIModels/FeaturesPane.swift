import FunesCore
import FunesProtocol
import SwiftUI

/// Settings ▸ AI ▸ Features (04-ux-mac.md, ADR-0030 §3, model providers §4): one row per job, each
/// opening its page; Apply changes automatically; and "What leaves this Mac ›".
struct FeaturesPane: View {
    let model: AppModel
    @State private var autoApply = AutoApplyLevel.off

    private var settings: ModelSettings { model.modelSettings }
    private var text: AIJobText { AIJobText(model: model) }

    var body: some View {
        Form {
            Section {
                NavigationLink(value: SettingsPage.newMemories) { newMemoriesRow }
                NavigationLink(value: SettingsPage.tidyUp) { tidyUpRow }
                NavigationLink(value: SettingsPage.searchAnswers) { searchAnswersRow }
                NavigationLink(value: SettingsPage.searchIndex) { searchIndexRow }
            } footer: {
                Text(String(localized: "Each feature uses a model from Models & Accounts."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section(String(localized: "Review")) {
                Picker(String(localized: "Apply changes automatically"), selection: $autoApply) {
                    Text(String(localized: "Off")).tag(AutoApplyLevel.off)
                    Text(String(localized: "Duplicates only")).tag(AutoApplyLevel.duplicatesOnly)
                        .disabled(text.highestLevel < .duplicatesOnly)
                    Text(String(localized: "Everything except conflicts")).tag(AutoApplyLevel.exceptConflicts)
                        .disabled(text.highestLevel < .exceptConflicts)
                }
                .onChange(of: autoApply) { _, level in model.preferences.applyAutomatically = level }
                Text(text.autoApplyCaption).font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Button {
                    model.showSettingsPane(.privacy)
                } label: {
                    HStack {
                        Text(String(localized: "What leaves this Mac"))
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .formStyle(.grouped)
        .onAppear { autoApply = model.preferences.applyAutomatically }
        .aiSettingsRefresh(model)
    }

    // MARK: Rows

    private var newMemoriesRow: some View {
        let split = model.preferences.splitNewMemories && text.canSplit
        let summary = model.preferences.classifyCaptures
            ? String(localized: "Proposes a title, kind and categories") + (split ? " · " + String(localized: "Splits notes") : "")
            : split ? String(localized: "Splits notes") : String(localized: "Simple rules on this Mac")
        return JobRow(title: String(localized: "New memories"), summary: summary, job: .newMemories, model: model)
    }

    private var tidyUpRow: some View {
        var summary = String(localized: "Off")
        if model.preferences.tidyUpDaily {
            let time = model.preferences.tidyUpSchedule
            let at = Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date())?
                .formatted(date: .omitted, time: .shortened) ?? ""
            summary = String(localized: "Daily at \(at)") + " · " + (model.tidyUp.lastRun.map { run in
                let when = Calendar.current.isDateInToday(run.startedAt) ? String(localized: "today")
                    : Calendar.current.isDateInYesterday(run.startedAt) ? String(localized: "yesterday") : RelativeTime.full(run.startedAt)
                return run.suggestions == 1 ? String(localized: "Last run \(when), 1 suggestion")
                    : String(localized: "Last run \(when), \(run.suggestions) suggestions")
            } ?? String(localized: "Not run yet"))
        }
        return JobRow(title: String(localized: "Daily tidy-up"), summary: summary, job: .tidyUp, model: model)
    }

    private var searchAnswersRow: some View {
        let trigger = settings.searchAnswersOnDevice ? .ask : settings.searchAnswersTrigger
        let mode = switch trigger {
        case .ask: String(localized: "Only when you ask (⌘⏎)")
        case .questions: String(localized: "Automatically for questions")
        case .everySearch: String(localized: "Automatically for every search")
        }
        let summary = settings.searchAnswersOn ? mode : String(localized: "Off")
        return JobRow(title: String(localized: "Search answers"), summary: summary, job: settings.searchAnswersOn ? .searchAnswers : nil,
                      model: model)
    }

    private var searchIndexRow: some View {
        var summary = model.services.hasEmbeddings ? String(localized: "Built in (bge-small) · Ready")
                                                   : String(localized: "Built in (bge-small) · Unavailable")
        var locality = Locality.onDevice
        if let choice = settings.embedding {
            let controller = model.embeddings
            let state: String = if controller.problem != nil { String(localized: "Needs attention") }
                else if controller.isComplete { String(localized: "Ready") }
                else if let p = controller.progress, p.total > 0 { String(localized: "Embedding \(p.done) of \(p.total)") }
                else { String(localized: "Starting…") }
            summary += " · \(choice.model) (\(settings.name(choice.provider))): \(state)"
            locality = controller.locality ?? settings.locality(account: choice.provider)
        }
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Search index"))
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            LocalityPill(locality: locality)
        }
    }
}

/// A Features row: the job, its summary, and the model and badge, or what's missing in orange.
struct JobRow: View {
    let title: String
    let summary: String
    /// Nil while the job is off (Search answers): no model shown.
    let job: AIJob?
    let model: AppModel

    private var settings: ModelSettings { model.modelSettings }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let job {
                if let problem = settings.problem(job) {
                    ProblemLabel(text: ProviderText.label(problem))
                } else {
                    let resolution = settings.resolve(job)
                    Text(trailing(resolution)).foregroundStyle(.secondary).lineLimit(1)
                    LocalityPill(locality: settings.locality(resolution.model))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Claude · haiku", "Same model", "Apple on-device", "Rules only".
    private func trailing(_ resolution: Resolution) -> String {
        if resolution.follows, resolution.model != .rules { return String(localized: "Same model") }
        switch resolution.model {
        case .onDevice: return String(localized: "Apple on-device")
        case .rules: return String(localized: "Rules only")
        case let .model(account, model): return "\(PlanKind(rawValue: account)?.plan ?? settings.name(account)) · \(model)"
        case let .unresolved(account): return settings.name(account)
        }
    }
}

/// What's missing, after a row: an orange icon and primary text (orange text on white is under
/// 3:1).
struct ProblemLabel: View {
    let text: String
    var body: some View {
        Label {
            Text(text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
        }
        .font(.callout)
        .lineLimit(1)
    }
}

/// The locality badge: green on this Mac or a local server, orange for a cloud model.
struct LocalityPill: View {
    let locality: Locality
    var body: some View { Pill(label: locality.title, tone: locality.isLocal ? .good : .warning) }
}

/// A job's model pop-up (ADR-0030 §6): Same as New memories and Apple on-device where allowed,
/// then every account's models grouped by account with why it can't run now, then Add a Model…,
/// which opens Models & Accounts.
struct ModelPicker: View {
    let model: AppModel
    let job: AIJob
    var changed: () -> Void = {}

    private var settings: ModelSettings { model.modelSettings }

    private enum Tag: Hashable {
        case choice(JobChoice)
        case noModels(String)
        case addModel
    }

    var body: some View {
        let current = settings.choice(job)
        Menu {
            Picker(selection: Binding<Tag>(get: { .choice(current) }, set: choose)) {
                if job.canFollow { Text(String(localized: "Same as New memories")).tag(Tag.choice(.followsNewMemories)) }
                if job.canUseOnDevice { Text(String(localized: "Apple on-device")).tag(Tag.choice(.onDevice)) }
                ForEach(settings.pickerSections(job), id: \.account) { section in
                    Section(header(section)) {
                        if let chosen = current.modelChoice, chosen.account == section.account, chosen.model == nil {
                            Text(String(localized: "\(settings.name(section.account)) · Choose a model")).tag(Tag.choice(current))
                        }
                        ForEach(section.models, id: \.self) { name in
                            Text(name).tag(Tag.choice(.model(ModelChoice(account: section.account, model: name))))
                        }
                        if section.models.isEmpty {
                            Text(String(localized: "No models")).tag(Tag.noModels(section.account)).disabled(true)
                        }
                    }
                }
                Divider()
                Text(String(localized: "Add a Model…")).tag(Tag.addModel)
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(label(current))
        }
        .fixedSize()
        .accessibilityLabel(String(localized: "Model: \(label(current))"))
    }

    private func header(_ section: PickerSection) -> String {
        let name = settings.name(section.account)
        return section.problem.map { "\(name) — \(ProviderText.reason($0))" } ?? name
    }

    private func label(_ choice: JobChoice) -> String {
        switch choice {
        case .followsNewMemories: String(localized: "Same as New memories")
        case .onDevice: String(localized: "Apple on-device")
        case let .model(chosen):
            chosen.model.map { "\(settings.name(chosen.account)) · \($0)" }
                ?? String(localized: "\(settings.name(chosen.account)) · Choose a model")
        }
    }

    private func choose(_ tag: Tag) {
        switch tag {
        case let .choice(choice):
            guard choice != settings.choice(job) else { return }
            settings.setChoice(choice, for: job)
            changed()
        case .addModel:
            model.showSettingsPane(.accounts)
        case .noModels:
            break
        }
    }
}

/// A job page's Model row: the pop-up and the effective model's badge.
struct ModelRow: View {
    let model: AppModel
    let job: AIJob
    var changed: () -> Void = {}

    var body: some View {
        LabeledContent(String(localized: "Model")) {
            HStack(spacing: 6) {
                ModelPicker(model: model, job: job, changed: changed)
                let resolution = model.modelSettings.resolve(job)
                if case .unresolved = resolution.model {} else {
                    LocalityPill(locality: model.modelSettings.locality(resolution.model))
                }
            }
        }
    }
}

// MARK: - Pages

/// Features ▸ New memories: the model, its status and disclosure, proposals and splitting.
struct NewMemoriesPage: View {
    let model: AppModel
    /// Mirrors `Preferences.classifyCaptures` and `splitNewMemories`.
    @State private var classify = true
    @State private var split = false

    private var text: AIJobText { AIJobText(model: model) }

    var body: some View {
        Form {
            Section {
                ModelRow(model: model, job: .newMemories) { model.processing.updateSplitting() }
                Text(text.newMemoriesStatus).font(.callout).foregroundStyle(.secondary)
                if let disclosure = text.newMemoriesDisclosure(split: split) {
                    WarningLabel(text: disclosure, symbol: "arrow.up.forward.app")
                }
            }
            Section {
                Toggle(String(localized: "Propose a title, kind and categories"), isOn: $classify)
                    .onChange(of: classify) { _, on in model.preferences.classifyCaptures = on }
                Toggle(String(localized: "Split into separate memories"), isOn: $split)
                    .disabled(!text.canSplit)
                    .onChange(of: split) { _, on in
                        model.preferences.splitNewMemories = on
                        model.processing.updateSplitting()
                    }
                Text(text.splitCaption(classify: classify, split: split)).font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            classify = model.preferences.classifyCaptures
            split = model.preferences.splitNewMemories
        }
        .aiSettingsRefresh(model)
    }
}

/// Features ▸ Daily tidy-up (memory processing §9): the schedule, Tidy Up Now, the model (never
/// Apple on-device), the caption with the last run or the estimate, and the disclosure.
struct TidyUpPage: View {
    let model: AppModel
    /// Mirrors `Preferences.tidyUpDaily` and `tidyUpSchedule`.
    @State private var daily = false
    @State private var time = Date()

    private var text: AIJobText { AIJobText(model: model) }

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Schedule")) {
                    HStack(spacing: 8) {
                        Picker(String(localized: "Schedule"), selection: $daily) {
                            Text(String(localized: "Off")).tag(false)
                            Text(String(localized: "Daily")).tag(true)
                        }
                        .labelsHidden().fixedSize()
                        .onChange(of: daily) { _, on in
                            guard on != model.preferences.tidyUpDaily else { return }
                            model.preferences.tidyUpDaily = on
                            // The notification after a run with results (§9.5).
                            if on { model.requestNotificationPermission { _ in } }
                        }
                        if daily {
                            DatePicker(String(localized: "At"), selection: $time, displayedComponents: .hourAndMinute)
                                .labelsHidden().fixedSize()
                                .onChange(of: time) { _, time in
                                    let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                                    model.preferences.tidyUpSchedule = TidyUpSchedule(hour: c.hour ?? 3, minute: c.minute ?? 0)
                                }
                        }
                        Button(model.tidyUp.running ? String(localized: "Tidying Up…") : String(localized: "Tidy Up Now")) {
                            Task { await model.tidyUp.runNow() }
                        }
                        .disabled(model.tidyUp.running)
                    }
                }
                ModelRow(model: model, job: .tidyUp)
                Text(text.tidyUpCaption).font(.callout).foregroundStyle(.secondary)
                if let disclosure = text.tidyUpDisclosure { WarningLabel(text: disclosure, symbol: "arrow.up.forward.app") }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            daily = model.preferences.tidyUpDaily
            let schedule = model.preferences.tidyUpSchedule
            time = Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: Date()) ?? Date()
        }
        .aiSettingsRefresh(model)
    }
}

/// Features ▸ Search answers (FR-AI-17): Answer, then the model, its status and disclosure.
struct SearchAnswersPage: View {
    let model: AppModel

    private var settings: ModelSettings { model.modelSettings }
    private var text: AIJobText { AIJobText(model: model) }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Answer"), selection: Binding(get: { settings.searchAnswersMode },
                                                                      set: { settings.searchAnswersMode = $0 })) {
                    Text(String(localized: "Off")).tag(AnswerTrigger?.none)
                    Text(String(localized: "Only when I ask")).tag(Optional(AnswerTrigger.ask))
                    Text(String(localized: "Automatically for questions")).tag(Optional(AnswerTrigger.questions))
                    Text(String(localized: "Automatically for every search")).tag(Optional(AnswerTrigger.everySearch))
                }
                if settings.searchAnswersOn {
                    ModelRow(model: model, job: .searchAnswers)
                    Text(text.searchAnswersStatus + " " + String(localized: "Each claim quotes the memory it came from, and claims it can't quote aren't shown."))
                        .font(.callout).foregroundStyle(.secondary)
                    if let disclosure = text.searchAnswersDisclosure { WarningLabel(text: disclosure, symbol: "arrow.up.forward.app") }
                }
            }
        }
        .formStyle(.grouped)
        .aiSettingsRefresh(model)
    }
}

/// Features ▸ Search index: the bundled bge-small and the optional second index (ADR-0023).
struct SearchIndexPage: View {
    let model: AppModel

    var body: some View {
        Form {
            Section { EmbeddingRows(model: model) }
        }
        .formStyle(.grouped)
        .aiSettingsRefresh(model)
    }
}

extension View {
    /// What the AI panes need fresh: the plans' checks, the accounts' localities, the tidy-up's
    /// last run.
    func aiSettingsRefresh(_ model: AppModel) -> some View {
        self
            .task { await model.modelSettings.refreshSubscriptions() }
            .task(id: model.modelSettings.accounts) { await model.modelSettings.resolveLocalities() }
            .task { await model.tidyUp.load() }
    }
}
