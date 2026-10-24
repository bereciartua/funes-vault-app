import FunesCore
import FunesProtocol
import SwiftUI

/// Settings ▸ AI Models (04-ux-mac.md, model-providers.md §4, FR-AI-05..08, FR-AI-12). Embeddings:
/// the bundled bge-small, plus optionally a provider model as a second index (ADR-0023).
struct ModelSettingsPane: View {
    let model: AppModel
    @State private var editing: ProviderConfig?
    @State private var adding: ProviderConfig?
    @State private var localities: [String: Locality] = [:]
    /// A cloud limit above Internal waiting for its one-time confirmation (ADR-0022).
    @State private var confirming: CloudLimit?
    /// Mirrors `Preferences.classifyCaptures` (moved here from Settings ▸ Capture, task 6.1.8).
    @State private var classify = true
    /// Mirrors `Preferences.splitNewMemories` and `applyAutomatically` (task 6a.6).
    @State private var split = false
    @State private var autoApply = AutoApplyLevel.off
    @State private var today: CloudRequestCap.Day?
    /// Mirrors `Preferences.tidyUpDaily` and `tidyUpSchedule` (task 6b.5).
    @State private var tidyUpDaily = false
    @State private var tidyUpTime = Date()

    private var settings: ModelSettings { model.modelSettings }

    var body: some View {
        Form {
            Section(String(localized: "Tasks")) {
                EmbeddingRows(model: model)
                LabeledContent(String(localized: "New memories")) {
                    HStack(spacing: 6) {
                        Picker(String(localized: "New memories"), selection: Binding(get: { settings.classifierID },
                                                                                    set: { settings.setClassifier($0) })) {
                            Text(String(localized: "Apple on-device")).tag(String?.none)
                            ForEach(settings.providers) { provider in
                                Text("\(provider.name) · \(provider.model.isEmpty ? String(localized: "no model") : provider.model)")
                                    .tag(Optional(provider.id))
                            }
                            ForEach(SubscriptionConfig.Kind.allCases) { kind in
                                if settings.executables[kind] != nil || settings.classifierID == kind.rawValue {
                                    Text("\(kind.name) · \(settings.subscription(kind).model)").tag(Optional(kind.rawValue))
                                }
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Pill(label: classifierLocality.title, tone: classifierLocality.isLocal ? .good : .warning)
                    }
                }
                Text(classificationStatus).font(.callout).foregroundStyle(.secondary)
                if let disclosure = classificationDisclosure {
                    WarningLabel(text: disclosure, symbol: "arrow.up.forward.app")
                }
                Toggle(String(localized: "Propose a title, kind and categories"), isOn: $classify)
                    .onChange(of: classify) { _, on in model.preferences.classifyCaptures = on }
                Toggle(String(localized: "Split into separate memories"), isOn: $split)
                    .disabled(!canSplit)
                    .onChange(of: split) { _, on in model.preferences.splitNewMemories = on }
                Text(splitCaption).font(.callout).foregroundStyle(.secondary)
                tidyUpRows
                Picker(String(localized: "Apply changes automatically"), selection: $autoApply) {
                    Text(String(localized: "Off")).tag(AutoApplyLevel.off)
                    Text(String(localized: "Duplicates only")).tag(AutoApplyLevel.duplicatesOnly)
                        .disabled(highestLevel < .duplicatesOnly)
                    Text(String(localized: "Everything except conflicts")).tag(AutoApplyLevel.exceptConflicts)
                        .disabled(highestLevel < .exceptConflicts)
                }
                .onChange(of: autoApply) { _, level in model.preferences.applyAutomatically = level }
                Text(autoApplyCaption).font(.callout).foregroundStyle(.secondary)
            }
            Section(String(localized: "Cloud limit")) {
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
            Section(String(localized: "Cloud requests per day")) {
                Stepper(value: Binding(get: { settings.dailyCap }, set: { settings.dailyCap = $0 }), in: 10...10_000, step: 50) {
                    LabeledContent(String(localized: "At most"), value: settings.dailyCap.formatted())
                }
                Text(capLine).font(.callout).foregroundStyle(.secondary)
            }
            Section(String(localized: "Use your subscription")) {
                ForEach(SubscriptionConfig.Kind.allCases) { kind in
                    SubscriptionRow(model: model, kind: kind)
                }
                Text(String(localized: "Uses your plan's limits, through the Claude Code or Codex you installed and signed in to. Funes never sees your sign-in. Your account's training setting applies."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section(String(localized: "Providers")) {
                if settings.providers.isEmpty {
                    Text(String(localized: "None yet. Funes uses Apple's on-device model, or simple rules when that isn't available."))
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.providers) { provider in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(provider.name).fontWeight(.medium)
                                if let locality = localities[provider.id] {
                                    Pill(label: locality.title, tone: locality.isLocal ? .good : .warning)
                                }
                            }
                            Text(provider.endpoint.baseURL.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(usageLine(provider.id)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(settings.hasKey(provider.id) ? String(localized: "Key in Keychain") : String(localized: "No key"))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(String(localized: "Edit…")) { editing = provider }
                            .accessibilityLabel(String(localized: "Edit \(provider.name)"))
                        Button(String(localized: "Remove"), role: .destructive) { settings.remove(provider.id) }
                            .accessibilityLabel(String(localized: "Remove \(provider.name)"))
                    }
                }
                HStack {
                    Menu(String(localized: "Add Provider")) {
                        ForEach(ProviderConfig.presets) { preset in
                            Button(preset.name) { adding = preset }
                                .disabled(settings.providers.contains { $0.id == preset.id })
                        }
                        Divider()
                        Button(String(localized: "Other OpenAI-Compatible Server…")) {
                            adding = ProviderConfig(endpoint: ProviderEndpoint(id: ProviderID(rawValue: "custom-\(UUID().uuidString.prefix(8).lowercased())"),
                                                                               kind: .openAICompatible,
                                                                               baseURL: URL(string: "http://127.0.0.1:8080/v1")!),
                                                    name: String(localized: "My Server"), model: "")
                        }
                    }
                    .fixedSize()
                    Spacer()
                    if !settings.stored.usage.isEmpty {
                        Button(String(localized: "Reset Usage")) { settings.resetUsage() }
                    }
                }
                Text(String(localized: "Keys are stored in the Keychain on this Mac only, never in the vault, exports or Activity."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { ProviderSheet(model: model, provider: $0, isNew: false) }
        .sheet(item: $adding) { ProviderSheet(model: model, provider: $0, isNew: true) }
        .task(id: settings.providers) { await resolveLocalities() }
        .task { await settings.refreshSubscriptions() }
        .onAppear {
            classify = model.preferences.classifyCaptures
            split = model.preferences.splitNewMemories
            autoApply = model.preferences.applyAutomatically
            tidyUpDaily = model.preferences.tidyUpDaily
            let schedule = model.preferences.tidyUpSchedule
            tidyUpTime = Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: Date()) ?? Date()
        }
        .task { await model.tidyUp.load() }
        .task(id: model.activityGeneration) {
            today = try? await settings.cap(store: model.services.store, activity: model.services.activity).today(now: Date())
        }
        .alert(String(localized: "Send more sensitive memories to cloud models?"),
               isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { limit in
            Button(String(localized: "Send Up to \(Self.title(limit))")) { settings.cloudLimit = limit }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { limit in
            Text(String(localized: "Memories up to \(Self.title(limit)) can then be sent to \(settings.chosenName ?? String(localized: "the cloud providers you choose")). They can include health, money, family or legal matters. Funes still never sends anything that looks like a secret."))
        }
    }

    /// Above Internal asks once to confirm, naming the provider (ADR-0022).
    private func choose(_ limit: CloudLimit) {
        if limit.needsConfirmation, !settings.cloudLimit.needsConfirmation {
            confirming = limit
        } else {
            settings.cloudLimit = limit
        }
    }

    static func title(_ limit: CloudLimit) -> String {
        switch limit {
        case .upTo(.secret): String(localized: "Everything, including Secret")
        case let .upTo(level): level.title
        case .never: String(localized: "Nothing")
        }
    }

    /// "Today: 12 of 300 (agents 3 of 120)." (ADR-0022)
    private var capLine: String {
        let cap = settings.dailyCap
        let agents = Int((Double(cap) * CloudRequestCap.agentShare).rounded(.down))
        let total = today?.total ?? 0, byAgents = today?.agents ?? 0
        return String(localized: "Today: \(total) of \(cap), agents \(byAgents) of \(agents). Shared by every task that uses a cloud model; on-device models and embeddings don't count. At the limit, new captures are classified on this Mac until tomorrow.")
    }

    // MARK: Daily tidy-up (memory processing §9, task 6b.5)

    @ViewBuilder
    private var tidyUpRows: some View {
        LabeledContent(String(localized: "Daily tidy-up")) {
            HStack(spacing: 8) {
                Picker(String(localized: "Daily tidy-up"), selection: $tidyUpDaily) {
                    Text(String(localized: "Off")).tag(false)
                    Text(String(localized: "Daily")).tag(true)
                }
                .labelsHidden().fixedSize()
                .onChange(of: tidyUpDaily) { _, on in
                    guard on != model.preferences.tidyUpDaily else { return }
                    model.preferences.tidyUpDaily = on
                    // The notification after a run with results (§9.5).
                    if on { model.requestNotificationPermission { _ in } }
                }
                if tidyUpDaily {
                    DatePicker(String(localized: "At"), selection: $tidyUpTime, displayedComponents: .hourAndMinute)
                        .labelsHidden().fixedSize()
                        .onChange(of: tidyUpTime) { _, time in
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
        LabeledContent(String(localized: "Tidy-up model")) {
            Picker(String(localized: "Tidy-up model"), selection: Binding(get: { settings.tidyUpID }, set: { settings.setTidyUp($0) })) {
                Text(String(localized: "Same as New memories")).tag(String?.none)
                ForEach(settings.providers) { provider in
                    Text("\(provider.name) · \(provider.model.isEmpty ? String(localized: "no model") : provider.model)")
                        .tag(Optional(provider.id))
                }
                ForEach(SubscriptionConfig.Kind.allCases) { kind in
                    if settings.executables[kind] != nil || settings.tidyUpID == kind.rawValue {
                        Text("\(kind.name) · \(settings.subscription(kind).model)").tag(Optional(kind.rawValue))
                    }
                }
            }
            .labelsHidden().fixedSize()
        }
        Text(tidyUpCaption).font(.callout).foregroundStyle(.secondary)
        if let disclosure = tidyUpDisclosure { WarningLabel(text: disclosure, symbol: "arrow.up.forward.app") }
    }

    /// Compares changed memories with related ones and proposes updates, merges, splits, archives
    /// and questions; the last run, or before the first, the estimate (§9.6).
    private var tidyUpCaption: String {
        var lines = [settings.tidyUpName == nil
            ? String(localized: "Finds exact duplicates and expired memories on this Mac. Choose a local server or a cloud model to also find updates, merges, splits and conflicts; Apple's on-device model isn't used for this.")
            : String(localized: "Compares memories that changed with related ones and proposes updates, merges, splits and archives, and asks you about conflicts. Proposals wait in the Inbox's Tidy-up section.")]
        if let run = model.tidyUp.lastRun {
            lines.append(TidyUpController.summary(run))
        } else if let estimate = model.tidyUp.estimate, settings.tidyUpName != nil {
            lines.append(String(localized: "About \(estimate.memories) memories to check. Roughly \(estimate.requests) requests the first week, then a few a day."))
        }
        return lines.joined(separator: " ")
    }

    /// "The daily tidy-up sends related memories (up to Internal) to Anthropic." (model providers §4)
    private var tidyUpDisclosure: String? {
        guard let name = settings.tidyUpName, let modelID = settings.tidyUpModel, !modelID.isEmpty else { return nil }
        let isPlan = SubscriptionConfig.Kind(rawValue: settings.tidyUpID ?? settings.classifierID ?? "") != nil
        if !isPlan, let id = settings.tidyUpID ?? settings.classifierID, let provider = settings.providers.first(where: { $0.id == id }),
           (localities[provider.id] ?? (provider.endpoint.markedCloud ? .cloud : .localServer)).isLocal {
            return nil
        }
        switch settings.cloudLimit {
        case .never: return String(localized: "The daily tidy-up sends nothing to \(name): the cloud limit is Nothing, so only exact duplicates and expired memories are found.")
        case .upTo(let level): return String(localized: "The daily tidy-up sends related memories (up to \(Self.title(.upTo(level)))), with their dates and sources, to \(name).")
        }
    }

    /// The highest level either task's engine reached: New memories' (none yet) or the tidy-up's.
    private var highestLevel: AutoApplyLevel {
        max(NewMemoryAutoApply.highestAvailable, settings.tidyUpModel.map(TidyUpAutoApply.reached(model:)) ?? .off)
    }

    private var autoApplyCaption: String {
        let tidy = settings.tidyUpModel.map(TidyUpAutoApply.reached(model:)) ?? .off
        let tidyLine = switch tidy {
        case .off: String(localized: "The tidy-up's model hasn't been accurate enough to change memories by itself, so its proposals all wait for you.")
        case .duplicatesOnly: String(localized: "With this model the tidy-up can archive duplicates by itself; everything else waits for you.")
        case .exceptConflicts: String(localized: "With this model the tidy-up can apply updates, merges, splits and archives by itself; conflicts always wait for you.")
        }
        return String(localized: "Off: every proposal waits for you in the Inbox. No model has been accurate enough yet to save new memories by itself. Agents always follow their own access.") + " " + tidyLine + " " + String(localized: "Undo any automatic change for 30 days in the Inbox.")
    }

    /// Splitting needs a local server or a cloud model with a model chosen; Apple on-device only
    /// proposes fields (memory processing §5.2).
    private var canSplit: Bool {
        if let plan = settings.chosenSubscription { return !plan.model.isEmpty }
        guard let provider = settings.classifier, !provider.model.isEmpty else { return false }
        return classifierLocality != .onDevice
    }

    private var splitCaption: String {
        guard canSplit else {
            return String(localized: "Splitting needs a local server or a cloud model. Apple's on-device model proposes fields only.")
        }
        if split {
            return String(localized: "Captures, your answers, agents' suggestions and imports become one suggestion per claim, each marked new, an update, already saved or a removal. You review every piece in the Inbox.")
        }
        return classify ? String(localized: "You review every proposal in the Inbox.")
                        : String(localized: "Captures get simple proposals from rules on this Mac.")
    }

    private var classifierLocality: Locality {
        if settings.chosenSubscription != nil { return .cloud }
        guard let provider = settings.classifier else { return .onDevice }
        return localities[provider.id] ?? (provider.endpoint.markedCloud ? .cloud : .localServer)
    }

    private var classificationStatus: String {
        if let plan = settings.chosenSubscription {
            let status = settings.subscriptionStatus[plan.kind].map { SubscriptionRow.text($0, plan.kind) } ?? String(localized: "Checking…")
            return status + " " + String(localized: "If it fails, Funes uses the on-device model, then rules.")
        }
        if let provider = settings.classifier {
            if provider.model.isEmpty { return String(localized: "Choose a model in \(provider.name)'s settings. Until then: on-device, then rules.") }
            if provider.endpoint.kind == .anthropic && !settings.hasKey(provider.id) {
                return String(localized: "Unavailable: check API key. Using on-device instead.")
            }
            return String(localized: "Ready. If it fails, Funes uses the on-device model, then rules.")
        }
        return AppleFoundationGenerator.isAvailable
            ? String(localized: "Ready")
            : String(localized: "Apple Intelligence isn't available on this Mac: simple rules propose the fields.")
    }

    /// "New memories sends new captures (up to Internal) and your category names and descriptions to
    /// Anthropic." (FR-AI-08) Only captures are classified in v0.1.
    private var classificationDisclosure: String? {
        if let plan = settings.chosenSubscription {
            switch settings.cloudLimit {
            case .never:
                return String(localized: "New memories sends nothing to \(plan.kind.plan): the cloud limit is Nothing, so it runs on this Mac.")
            case .upTo(let level) where split:
                return String(localized: "New memories sends captures, agent suggestions and imports, plus related memories (up to \(Self.title(.upTo(level)))), to \(plan.kind.plan) through your \(plan.kind == .claudeCode ? "Claude Code" : "Codex") sign-in. It counts toward your plan's limits, and your \(plan.kind.plan) account's training setting applies.")
            case .upTo(let level):
                return String(localized: "New memories sends new captures (up to \(Self.title(.upTo(level)))) and your category names and descriptions to \(plan.kind.plan) through your \(plan.kind == .claudeCode ? "Claude Code" : "Codex") sign-in. It counts toward your plan's limits, and your \(plan.kind.plan) account's training setting applies.")
            }
        }
        guard let provider = settings.classifier, !classifierLocality.isLocal else { return nil }
        switch settings.cloudLimit {
        case .never:
            return String(localized: "New memories sends nothing to \(provider.name): the cloud limit is Nothing, so it runs on this Mac.")
        case .upTo(let level) where split && canSplit:
            return String(localized: "New memories sends new captures, your answers, agents' suggestions and saved memories, and imports (up to \(Self.title(.upTo(level)))), then each piece with up to 5 related memories, and your category names and descriptions, to \(provider.name).")
        case .upTo(let level):
            return String(localized: "New memories sends new captures (up to \(Self.title(.upTo(level)))) and your category names and descriptions to \(provider.name).")
        }
    }

    private func usageLine(_ id: String) -> String {
        let usage = settings.stored.usage[id] ?? ProviderUsage()
        return String(localized: "\(usage.requests) requests · \(usage.inputTokens) tokens in · \(usage.outputTokens) out")
    }

    /// Locality needs a DNS lookup for host names, so it's worked out off the main thread.
    private func resolveLocalities() async {
        let endpoints = settings.providers.map { ($0.id, $0.endpoint) }
        let resolved = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: endpoints.map { ($0.0, $0.1.locality()) })
        }.value
        localities = resolved
    }
}

/// Add or edit a provider: name, base URL, API key (Keychain), cloud flag, model, Test connection.
struct ProviderSheet: View {
    let model: AppModel
    @State var provider: ProviderConfig
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var url = ""
    @State private var models: [String] = []
    @State private var status: String?
    @State private var testing = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? String(localized: "Add \(provider.name)") : String(localized: "Edit \(provider.name)"))
                .font(.title3.weight(.semibold))
            Form {
                TextField(String(localized: "Name"), text: $provider.name)
                TextField(String(localized: "Base URL"), text: $url)
                SecureField(String(localized: "API key"), text: $key,
                            prompt: Text(model.modelSettings.hasKey(provider.id) ? String(localized: "Saved; type to replace")
                                                                                 : String(localized: "Stored in the Keychain")))
                if provider.endpoint.kind == .openAICompatible {
                    Toggle(String(localized: "It's a cloud service"), isOn: $provider.endpoint.markedCloud)
                    Text(String(localized: "Funes treats any server that isn't on this Mac or your local network as cloud, whatever this says."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField(String(localized: "Model"), text: $provider.model)
                    if !models.isEmpty {
                        Menu(String(localized: "Choose")) {
                            ForEach(models, id: \.self) { name in Button(name) { provider.model = name } }
                        }
                        .fixedSize()
                    }
                    Button(String(localized: "Load Models")) { loadModels() }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button(testing ? String(localized: "Testing…") : String(localized: "Test Connection")) { test() }
                    .disabled(testing || provider.model.isEmpty)
                if let status { Text(status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Text(String(localized: "Test Connection classifies one made-up note among Funes's built-in categories; none of your memories or category names are sent."))
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? String(localized: "Add") : String(localized: "Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(provider.name.trimmingCharacters(in: .whitespaces).isEmpty || URL(string: url) == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { url = provider.endpoint.baseURL.absoluteString }
    }

    /// The provider as typed, with the key in a temporary store until it's saved.
    private func draft() throws -> (ProviderConfig, ModelSettings) {
        guard let base = URL(string: url.trimmingCharacters(in: .whitespaces)), base.scheme != nil else {
            throw ProviderError.unavailable
        }
        var draft = provider
        draft.endpoint.baseURL = base
        let keys = InMemoryProviderKeyStore()
        let typed = key.isEmpty ? ((try? model.modelSettings.keys.key(for: provider.endpoint.id)) ?? nil) : key
        if let typed, !typed.isEmpty { try keys.setKey(typed, for: provider.endpoint.id) }
        let scratch = ModelSettings(defaults: UserDefaults(suiteName: "funes-provider-draft") ?? .standard, keys: keys)
        return (draft, scratch)
    }

    private func loadModels() {
        status = nil
        Task {
            do {
                let (draft, scratch) = try draft()
                let client = try scratch.client(for: draft)
                if let openAI = client as? OpenAICompatibleClient {
                    models = try await openAI.listModels()
                } else if let anthropic = client as? AnthropicClient {
                    models = try await anthropic.listModels()
                }
                status = models.isEmpty ? String(localized: "The server listed no models.") : String(localized: "\(models.count) models")
            } catch {
                status = Self.text(error)
            }
        }
    }

    private func test() {
        testing = true
        status = nil
        Task {
            defer { testing = false }
            do {
                let (draft, scratch) = try draft()
                let started = Date()
                let proposal = try await ModelRouter.testConnection(try scratch.client(for: draft))
                let seconds = Date().timeIntervalSince(started).formatted(.number.precision(.fractionLength(1)))
                status = String(localized: "Works: it proposed “\(proposal.title)” in \(seconds) s.")
            } catch {
                status = Self.text(error)
            }
        }
    }

    private func save() {
        do {
            let (draft, _) = try draft()
            try model.modelSettings.upsert(draft, key: key.isEmpty ? nil : key)
            dismiss()
        } catch {
            self.error = String(localized: "The key couldn't be saved in the Keychain.")
        }
    }

    static func text(_ error: Error) -> String {
        switch error as? ProviderError {
        case .unauthorized?: String(localized: "Unavailable: check the API key.")
        case .rateLimited?: String(localized: "The provider says to slow down. Try again later.")
        case .server(let status)?: String(localized: "The provider answered with an error (\(status)).")
        case .invalidOutput?: String(localized: "The model's answer wasn't usable. Try another model.")
        case .refused?: String(localized: "The model declined.")
        case .timeout?: String(localized: "No answer within 20 seconds.")
        case .insecureEndpoint?: String(localized: "Cloud providers need an https:// address.")
        case .unavailable?: String(localized: "Check the address and the key.")
        case .blocked?: String(localized: "Funes didn't send it: it looked like a secret, or was above the cloud limit.")
        case .capReached?: String(localized: "Today's cloud requests are used up. Try again tomorrow, or raise the limit.")
        case .transport?, nil: String(localized: "Couldn't reach the server.")
        }
    }
}

/// One plan in Use your subscription (ADR-0024): whether its CLI is found and signed in, the
/// command to sign in, the model, Test Connection (one made-up note), and the vendor's privacy
/// settings. No key field: Funes never handles the plan's credentials.
struct SubscriptionRow: View {
    let model: AppModel
    let kind: SubscriptionConfig.Kind
    @State private var modelName = ""
    @State private var testing = false
    @State private var result: String?
    @State private var allowFileReads = false

    private var settings: ModelSettings { model.modelSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(kind.name).fontWeight(.medium)
                Pill(label: Locality.cloud.title, tone: .warning)
                Spacer()
                Text(settings.subscriptionStatus[kind].map { Self.text($0, kind) } ?? String(localized: "Checking…"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if settings.executables[kind] != nil, kind == .codex {
                Toggle(String(localized: "Use Codex even though it can read files on this Mac"), isOn: $allowFileReads)
                    .onChange(of: allowFileReads) { _, on in
                        settings.codexAllowsFileReads = on
                        Task { await settings.refreshSubscriptions() }
                    }
                WarningLabel(text: String(localized: "Codex can run commands that read files on this Mac. Funes runs it in an empty folder, read-only, with no internet, and discards any run that uses a command, but it can't switch this ability off. Use it only if you accept that."))
            }
            if settings.executables[kind] != nil {
                HStack {
                    TextField(String(localized: "Model"), text: $modelName)
                        .onSubmit { settings.setSubscriptionModel(kind, modelName) }
                    Menu(String(localized: "Choose")) {
                        ForEach(kind.suggestedModels, id: \.self) { name in
                            Button(name) {
                                modelName = name
                                settings.setSubscriptionModel(kind, name)
                            }
                        }
                    }
                    .fixedSize()
                    Button(testing ? String(localized: "Testing…") : String(localized: "Test Connection")) { test() }
                        .disabled(testing || modelName.isEmpty)
                }
                HStack {
                    if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Link(String(localized: "\(kind.plan) Privacy Settings"), destination: kind.privacySettings).font(.caption)
                }
            }
        }
        .onAppear {
            modelName = settings.subscription(kind).model
            allowFileReads = settings.codexAllowsFileReads
        }
        .accessibilityElement(children: .contain)
    }

    /// "Signed in to Claude Code", "Not signed in: run `claude` in Terminal and sign in"…
    static func text(_ status: SubscriptionStatus, _ kind: SubscriptionConfig.Kind) -> String {
        let tool = kind == .claudeCode ? "Claude Code" : "Codex"
        switch status {
        case let .ready(version): return String(localized: "Signed in to \(tool) \(version)")
        case .notInstalled: return String(localized: "\(tool) isn't installed on this Mac")
        case .notSignedIn: return String(localized: "Not signed in: run `\(kind.signIn)` in Terminal and sign in with \(kind.plan)")
        case .needsUpdate: return String(localized: "Update \(tool) to use it")
        case .unsupportedFeatures: return String(localized: "This \(tool) version isn't supported yet")
        case .fileReadsNotAllowed: return String(localized: "Off: it can read files on this Mac. Turn on the switch below to use it anyway.")
        case .blocked: return String(localized: "Unavailable: it tried to use a tool. Test Connection to try again.")
        }
    }

    /// One made-up note through the same guardrails, after clearing a tool block.
    private func test() {
        settings.setSubscriptionModel(kind, modelName)
        guard let client = settings.subscriptionClient(kind) else { return }
        testing = true
        Task {
            CLIRunner.unblock(client.id)
            do {
                let proposal = try await ModelRouter.testConnection(client, timeout: CLIRunner.timeout)
                result = String(localized: "Works: proposed “\(proposal.title)”.")
            } catch {
                result = switch error as? ProviderError {
                case .unauthorized?: String(localized: "Not signed in: run `\(kind.signIn)` in Terminal and sign in with \(kind.plan).")
                case .rateLimited?: String(localized: "Your \(kind.plan) plan's limit is reached. Try again later.")
                case .timeout?: String(localized: "No answer within 90 seconds.")
                case .unavailable?: String(localized: "Unavailable: see the status above.")
                default: ProviderSheet.text(error)
                }
            }
            await settings.refreshSubscriptions()
            testing = false
        }
    }
}
