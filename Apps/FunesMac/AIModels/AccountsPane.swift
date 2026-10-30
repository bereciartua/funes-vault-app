import FunesCore
import FunesProtocol
import SwiftUI

/// Settings ▸ AI ▸ Models & Accounts (04-ux-mac.md, ADR-0030 §4): where models come from, grouped
/// by how they're paid for, each row saying which jobs use it and opening its page.
struct AccountsPane: View {
    let model: AppModel
    @State private var adding: AIAccount?

    private var settings: ModelSettings { model.modelSettings }

    var body: some View {
        Form {
            Section(String(localized: "Built in")) {
                AccountRow(name: String(localized: "Apple on-device"),
                           usedBy: UsedByText.jobs(onDeviceJobs, settings: settings),
                           state: AppleFoundationGenerator.isAvailable ? String(localized: "Ready") : String(localized: "Not available on this Mac"),
                           locality: .onDevice)
                Button {
                    model.goToSettings(.searchIndex)
                } label: {
                    AccountRow(name: "bge-small", usedBy: String(localized: "Used by: Search index"),
                               state: model.services.hasEmbeddings ? String(localized: "Ready") : String(localized: "Unavailable"),
                               locality: .onDevice, chevron: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Section(String(localized: "Your plans")) {
                ForEach(PlanKind.allCases) { kind in
                    NavigationLink(value: SettingsPage.account(kind.rawValue)) {
                        AccountRow(name: kind.name, usedBy: usedBy(kind.rawValue), state: planState(kind), locality: .cloud,
                                   problem: problem(kind.rawValue))
                    }
                }
            }
            accountSection(String(localized: "API keys"), accounts: settings.accounts.filter { !isLocal($0) })
            accountSection(String(localized: "Local servers"), accounts: settings.accounts.filter(isLocal))
            Section {
                Text(String(localized: "Keys are stored in the Keychain on this Mac only, never in the vault, exports or Activity."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu(String(localized: "Add Account")) {
                    ForEach(AIAccount.presets) { preset in
                        Button(preset.name) { adding = preset }
                            .disabled(settings.hasAccount(preset.id))
                    }
                    Divider()
                    Button(String(localized: "Other OpenAI-Compatible Server…")) { adding = AIAccount.custom() }
                }
                .fixedSize()
            }
        }
        .sheet(item: $adding) { account in
            AddAccountSheet(model: model, account: account) { added in
                model.settingsPath = [.account(added.id)]
            }
        }
        .aiSettingsRefresh(model)
    }

    /// Under Local servers when its endpoint resolves local; API keys otherwise (cloud until resolved).
    private func isLocal(_ account: AIAccount) -> Bool { settings.locality(account: account.id).isLocal }

    private var onDeviceJobs: [AIJob] {
        AIJob.allCases.filter { job in
            settings.resolve(job).model == .onDevice && (job != .searchAnswers || settings.searchAnswersOn)
        }
    }

    @ViewBuilder
    private func accountSection(_ title: String, accounts: [AIAccount]) -> some View {
        Section(title) {
            if accounts.isEmpty {
                Text(String(localized: "None. Add one with Add Account…")).foregroundStyle(.secondary)
            }
            ForEach(accounts) { account in
                NavigationLink(value: SettingsPage.account(account.id)) {
                    AccountRow(name: account.name, usedBy: usedBy(account.id), state: state(account),
                               locality: settings.locality(account: account.id),
                               problem: problem(account.id))
                }
            }
        }
    }

    /// What's wrong, for an account a job uses; an unused one shows its plain state.
    private func problem(_ id: String) -> String? {
        guard !settings.usedBy(id).isEmpty else { return nil }
        return settings.problem(account: id).map(ProviderText.reason)
    }

    private func usedBy(_ id: String) -> String {
        if let kind = PlanKind(rawValue: id), settings.subscriptionStatus[kind] == .notInstalled, settings.usedBy(id).isEmpty {
            return String(localized: "Install \(kind.tool) and sign in to use your \(kind.plan) plan.")
        }
        return UsedByText.line(settings.usedBy(id), searchAnswersOn: settings.searchAnswersOn)
    }

    /// "Signed in", "Not signed in", "Not installed"…
    private func planState(_ kind: PlanKind) -> String {
        switch settings.subscriptionStatus[kind] {
        case nil: String(localized: "Checking…")
        case .ready?: String(localized: "Signed in")
        case .notInstalled?: String(localized: "Not installed")
        case .notSignedIn?: String(localized: "Not signed in")
        case .needsUpdate?: String(localized: "Update \(kind.tool) to use it")
        case .unsupportedFeatures?: String(localized: "Not supported yet")
        case .fileReadsNotAllowed?: String(localized: "Off: needs your OK to read files")
        case .blocked?: String(localized: "Paused after a tool use")
        }
    }

    /// "Key in Keychain", "No key"; for a local server its number of models.
    private func state(_ account: AIAccount) -> String {
        if isLocal(account) {
            return account.models.isEmpty ? String(localized: "No models")
                : account.models.count == 1 ? String(localized: "1 model") : String(localized: "\(account.models.count) models")
        }
        return settings.hasKey(account.id) ? String(localized: "Key in Keychain") : String(localized: "No key")
    }
}

/// "Used by: New memories, Daily tidy-up" (ADR-0030 §4).
enum UsedByText {
    static func job(_ job: AIJob) -> String {
        switch job {
        case .newMemories: String(localized: "New memories")
        case .tidyUp: String(localized: "Daily tidy-up")
        case .searchAnswers: String(localized: "Search answers")
        }
    }

    static func jobs(_ jobs: [AIJob], settings: ModelSettings) -> String {
        jobs.isEmpty ? String(localized: "Used by: none") : String(localized: "Used by: \(jobs.map(job).formatted(.list(type: .and)))")
    }

    /// Search answers counts only while they're on.
    static func line(_ uses: [AccountUse], searchAnswersOn: Bool) -> String {
        let names: [String] = uses.compactMap { use in
            switch use {
            case let .job(job, _, _): job == .searchAnswers && !searchAnswersOn ? nil : self.job(job)
            case .secondIndex: String(localized: "Search index")
            }
        }
        return names.isEmpty ? String(localized: "Used by: none") : String(localized: "Used by: \(names.formatted(.list(type: .and)))")
    }
}

/// A Models & Accounts row: name, Used by, state and badge.
struct AccountRow: View {
    let name: String
    let usedBy: String
    let state: String
    let locality: Locality
    var problem: String?
    var chevron = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(usedBy).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let problem {
                ProblemLabel(text: problem)
            } else {
                Text(state).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            LocalityPill(locality: locality)
            if chevron { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Account page

/// An account's or plan's page (04-ux-mac.md ▸ Account page). An id that no longer exists shows
/// nothing and goes back to Models & Accounts.
struct AccountPage: View {
    let model: AppModel
    let id: String

    var body: some View {
        Group {
            if let kind = PlanKind(rawValue: id) {
                PlanPage(model: model, kind: kind)
            } else if let account = model.modelSettings.account(id) {
                APIAccountPage(model: model, account: account)
            } else {
                Color.clear.onAppear { model.settingsPath = [] }
            }
        }
        // Each account's page is its own view: going from one account straight to another (a deep
        // link, Used by) must not keep the previous page's fields.
        .id(id)
        .navigationTitle(model.modelSettings.name(id))
    }
}

/// The parts both account pages share: Models, Used by, Test and Usage.
struct AccountSections {
    let model: AppModel
    let id: String
    private var settings: ModelSettings { model.modelSettings }

    /// "Daily tidy-up uses claude-opus-5-5. Remove it? The tidy-up will use the same model as New
    /// memories." (04-ux-mac.md)
    static func removalMessage(_ effect: RemovalEffect, model name: String, settings: ModelSettings) -> String {
        var lines: [String] = []
        for job in effect.direct {
            let reset = switch job {
            case .newMemories: String(localized: "New memories will use Apple on-device.")
            case .tidyUp: String(localized: "The tidy-up will use the same model as New memories.")
            case .searchAnswers: String(localized: "Search answers will use the same model as New memories.")
            }
            lines.append(String(localized: "\(UsedByText.job(job)) uses \(name).") + " " + reset)
        }
        for job in effect.followers {
            lines.append(job == .tidyUp
                ? String(localized: "Daily tidy-up follows New memories and will use its rules only.")
                : String(localized: "\(UsedByText.job(job)) follows New memories and will use Apple on-device."))
        }
        return lines.joined(separator: " ")
    }
}

/// Models: the list with Remove, and Add with Load Models (an account) or the suggestions (a plan).
struct ModelListSection: View {
    let model: AppModel
    let id: String
    /// Loads the server's models (an account); nil for a plan.
    var load: (() async throws -> [String])?
    var caption: String
    @State private var typed = ""
    @State private var loaded: [String] = []
    @State private var message: String?
    @State private var removing: String?

    private var settings: ModelSettings { model.modelSettings }
    private var models: [String] { settings.models(of: id) }

    var body: some View {
        Section(String(localized: "Models")) {
            if models.isEmpty {
                Text(String(localized: "No models yet. Add the chat models you want to use.")).foregroundStyle(.secondary)
            }
            ForEach(models, id: \.self) { name in
                HStack {
                    Text(name)
                    Spacer()
                    Button(String(localized: "Remove")) { remove(name) }
                        .disabled(!settings.stored.canRemove(model: name, from: id))
                        .accessibilityLabel(String(localized: "Remove \(name)"))
                }
            }
            HStack {
                TextField(String(localized: "Model name"), text: $typed, prompt: Text(String(localized: "Model name")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                    .onSubmit(add)
                Menu(load == nil ? String(localized: "Suggestions") : String(localized: "Load Models")) {
                    if let suggestions = PlanKind(rawValue: id)?.suggestedModels {
                        ForEach(suggestions.filter { !models.contains($0) }, id: \.self) { name in Button(name) { typed = name } }
                    } else if loaded.isEmpty {
                        Button(String(localized: "Load Models")) { loadModels() }
                    } else {
                        ForEach(loaded.filter { !models.contains($0) }, id: \.self) { name in Button(name) { typed = name } }
                        Divider()
                        Button(String(localized: "Load Again")) { loadModels() }
                    }
                }
                .fixedSize()
                Button(String(localized: "Add"), action: add)
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if EmbeddingCatalog.isEmbeddingModel(typed.trimmingCharacters(in: .whitespaces)) {
                WarningLabel(text: String(localized: "\(typed) is an embedding model: it can't propose fields, tidy up or answer. Choose it in Features ▸ Search index instead."))
            }
            Text(caption).font(.callout).foregroundStyle(.secondary)
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
        }
        .confirmationDialog(String(localized: "Remove \(removing ?? "")?"), isPresented: Binding(get: { removing != nil },
                                                                                                set: { if !$0 { removing = nil } }),
                            presenting: removing) { name in
            Button(String(localized: "Remove"), role: .destructive) { settings.removeModel(name, from: id) }
        } message: { name in
            Text(AccountSections.removalMessage(settings.stored.removalEffect(model: name, from: id), model: name, settings: settings))
        }
    }

    private func add() {
        if settings.addModel(typed, to: id) { typed = "" }
    }

    /// A model a job uses asks first; any other goes at once.
    private func remove(_ name: String) {
        if settings.stored.removalEffect(model: name, from: id).isEmpty {
            settings.removeModel(name, from: id)
        } else {
            removing = name
        }
    }

    private func loadModels() {
        guard let load else { return }
        message = nil
        Task {
            do {
                loaded = try await load()
                message = loaded.isEmpty ? String(localized: "The server listed no models.") : String(localized: "\(loaded.count) models")
            } catch {
                message = ProviderText.error(error)
            }
        }
    }
}

/// Used by: rows that open each job's page; the second index opens Search index.
struct UsedBySection: View {
    let model: AppModel
    let id: String

    var body: some View {
        let uses = model.modelSettings.usedBy(id).filter { use in
            if case .job(.searchAnswers, _, _) = use { return model.modelSettings.searchAnswersOn }
            return true
        }
        Section(String(localized: "Used by")) {
            if uses.isEmpty {
                Text(String(localized: "No feature uses this account.")).foregroundStyle(.secondary)
            }
            ForEach(uses, id: \.self) { use in
                Button {
                    model.goToSettings(destination(use))
                } label: {
                    HStack {
                        Text(title(use))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func title(_ use: AccountUse) -> String {
        switch use {
        case let .job(job, model, follows):
            let name = model.map { "\(UsedByText.job(job)) · \($0)" } ?? String(localized: "\(UsedByText.job(job)) · Choose a model")
            return follows ? String(localized: "\(name) (same as New memories)") : name
        case let .secondIndex(model): return String(localized: "Search index · \(model)")
        }
    }

    private func destination(_ use: AccountUse) -> SettingsDestination {
        switch use {
        case .job(.newMemories, _, _): .newMemories
        case .job(.tidyUp, _, _): .tidyUp
        case .job(.searchAnswers, _, _): .searchAnswers
        case .secondIndex: .searchIndex
        }
    }
}

/// Test: a model pop-up and Test Connection, with one made-up note; the result names the model.
struct TestSection: View {
    let model: AppModel
    let id: String
    @State private var chosen = ""
    @State private var testing = false
    @State private var result: String?

    private var settings: ModelSettings { model.modelSettings }

    var body: some View {
        let models = settings.models(of: id)
        Section(String(localized: "Test")) {
            HStack {
                Picker(String(localized: "Model"), selection: $chosen) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize()
                .disabled(models.isEmpty || testing)
                .onChange(of: chosen) { _, _ in result = nil }
                Button(testing ? String(localized: "Testing…") : String(localized: "Test Connection")) { test() }
                    .disabled(testing || !models.contains(chosen))
            }
            if let result { Text(result).font(.callout).fixedSize(horizontal: false, vertical: true) }
            Text(String(localized: "Test Connection classifies one made-up note among Funes's built-in categories; none of your memories or category names are sent."))
                .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { if !models.contains(chosen) { chosen = models.first ?? "" } }
        .onChange(of: models) { _, models in if !models.contains(chosen) { chosen = models.first ?? "" } }
    }

    private func test() {
        let name = chosen
        testing = true
        result = nil
        Task {
            defer { testing = false }
            if let kind = PlanKind(rawValue: id) {
                guard let client = settings.subscriptionClient(kind, model: name) else { return }
                CLIRunner.unblock(client.id)
                do {
                    let proposal = try await ModelRouter.testConnection(client, timeout: CLIRunner.timeout)
                    result = String(localized: "\(name) works: it proposed “\(proposal.title)”.")
                } catch {
                    result = switch error as? ProviderError {
                    case .unauthorized?: String(localized: "\(name): not signed in. Run `\(kind.signIn)` in Terminal and sign in with \(kind.plan).")
                    case .rateLimited?: String(localized: "\(name): your \(kind.plan) plan's limit is reached. Try again later.")
                    case .timeout?: String(localized: "No answer from \(name) within 90 seconds.")
                    case .unavailable?: String(localized: "\(name): unavailable, see the status above.")
                    default: "\(name): " + ProviderText.error(error)
                    }
                }
                await settings.refreshSubscriptions()
                return
            }
            guard let account = settings.account(id) else { return }
            do {
                let started = Date()
                let proposal = try await ModelRouter.testConnection(try settings.client(for: account, model: name))
                let seconds = Date().timeIntervalSince(started).formatted(.number.precision(.fractionLength(1)))
                result = String(localized: "\(name) works: it proposed “\(proposal.title)” in \(seconds) s.")
            } catch ProviderError.server(status: 400) {
                // A chat request the provider refused: usually a model that can't chat (an embedding model).
                result = EmbeddingCatalog.isEmbeddingModel(name)
                    ? String(localized: "\(name) is an embedding model, so it can't answer chat requests. Choose it in Features ▸ Search index, and test a chat model here.")
                    : String(localized: "The provider refused the request (400). Check that \(name) is a chat model the provider has.")
            } catch {
                result = "\(name): " + ProviderText.error(error)
            }
        }
    }
}

/// Usage: this account's counters, across its models, and Reset Usage (FR-AI-12).
struct UsageSection: View {
    let model: AppModel
    let id: String

    var body: some View {
        let usage = model.modelSettings.usage(id) ?? ProviderUsage()
        Section(String(localized: "Usage")) {
            HStack {
                Text(String(localized: "\(usage.requests) requests · \(usage.inputTokens) tokens in · \(usage.outputTokens) out"))
                Spacer()
                Button(String(localized: "Reset Usage")) { model.modelSettings.resetUsage(for: id) }
                    .disabled(usage.requests == 0)
            }
        }
    }
}

/// An API or local-server account's page: Connection (saved per field), Models, Used by, Test,
/// Usage, Remove Account….
struct APIAccountPage: View {
    let model: AppModel
    let account: AIAccount
    @State private var name = ""
    @State private var url = ""
    @State private var urlInvalid = false
    @State private var key = ""
    @State private var keyError: String?
    @State private var markedCloud = false
    @State private var confirmRemove = false
    @FocusState private var focus: Field?

    private enum Field { case name, url, key }

    private var settings: ModelSettings { model.modelSettings }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Text(account.name).font(.title3.weight(.semibold))
                    LocalityPill(locality: settings.locality(account: account.id))
                }
                Text(stateLine).font(.callout).foregroundStyle(.secondary)
            }
            Section(String(localized: "Connection")) {
                TextField(String(localized: "Name"), text: $name)
                    .focused($focus, equals: .name)
                    .onSubmit(saveName)
                VStack(alignment: .leading, spacing: 4) {
                    TextField(String(localized: "Base URL"), text: $url)
                        .focused($focus, equals: .url)
                        .onSubmit(saveURL)
                    if urlInvalid {
                        Text(String(localized: "That isn't a URL; the saved one is kept.")).font(.caption).foregroundStyle(.red)
                    }
                }
                LabeledContent(String(localized: "API key")) {
                    HStack {
                        SecureField(String(localized: "API key"), text: $key,
                                    prompt: Text(settings.hasKey(account.id) ? String(localized: "Saved; type to replace")
                                                                            : String(localized: "Stored in the Keychain")))
                            .labelsHidden()
                            .focused($focus, equals: .key)
                            .onSubmit(saveKey)
                        Button(String(localized: "Save Key"), action: saveKey).disabled(key.isEmpty)
                        if settings.hasKey(account.id) {
                            Button(String(localized: "Remove Key")) { setKey(nil) }
                        }
                    }
                }
                if let keyError { Text(keyError).font(.callout).foregroundStyle(.red) }
                if account.endpoint.kind == .openAICompatible {
                    Toggle(String(localized: "It's a cloud service"), isOn: $markedCloud)
                        .onChange(of: markedCloud) { _, on in
                            guard on != account.endpoint.markedCloud else { return }
                            var changed = account
                            changed.endpoint.markedCloud = on
                            settings.upsert(changed)
                        }
                    Text(String(localized: "Funes treats any server that isn't on this Mac or your local network as cloud, whatever this says."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ModelListSection(model: model, id: account.id, load: { [account, settings] in try await Self.listModels(account, settings) },
                             caption: String(localized: "Chat models, for New memories, the tidy-up and search answers. Embedding models are chosen in Features ▸ Search index."))
            UsedBySection(model: model, id: account.id)
            TestSection(model: model, id: account.id)
            UsageSection(model: model, id: account.id)
            Section {
                HStack {
                    Spacer()
                    Button(String(localized: "Remove Account…"), role: .destructive) { confirmRemove = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            name = account.name
            url = account.endpoint.baseURL.absoluteString
            markedCloud = account.endpoint.markedCloud
        }
        .onChange(of: focus) { old, _ in
            // Fields save when they lose focus, like About You; the key never does.
            if old == .name { saveName() }
            if old == .url { saveURL() }
        }
        .confirmationDialog(String(localized: "Remove \(account.name)?"), isPresented: $confirmRemove) {
            Button(String(localized: "Remove Account"), role: .destructive) {
                model.settingsPath = []
                settings.removeAccount(account.id)
            }
        } message: {
            Text(removeMessage)
        }
        .aiSettingsRefresh(model)
    }

    /// "Key in Keychain · Ready", "No key", "2 models".
    private var stateLine: String {
        var parts: [String] = []
        if account.requiresKey || settings.hasKey(account.id) {
            parts.append(settings.hasKey(account.id) ? String(localized: "Key in Keychain") : String(localized: "No key"))
        }
        parts.append(account.models.isEmpty ? String(localized: "No models")
                     : account.models.count == 1 ? String(localized: "1 model") : String(localized: "\(account.models.count) models"))
        if settings.problem(account: account.id) == nil, !account.models.isEmpty { parts.append(String(localized: "Ready")) }
        return parts.joined(separator: " · ")
    }

    private var removeMessage: String {
        let effect = settings.stored.removalEffect(account: account.id)
        var lines = [String(localized: "Its key is deleted from the Keychain and its usage is cleared.")]
        if !effect.direct.isEmpty || !effect.followers.isEmpty {
            let jobs = (effect.direct + effect.followers).map(UsedByText.job).formatted(.list(type: .and))
            lines.append(String(localized: "\(jobs) use it and go back to their default."))
        }
        if effect.secondIndex {
            lines.append(String(localized: "The second index uses it: its vectors are deleted and search uses bge-small alone."))
        }
        return lines.joined(separator: " ")
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { name = account.name; return }
        guard trimmed != account.name else { return }
        var changed = account
        changed.name = trimmed
        settings.upsert(changed)
    }

    private func saveURL() {
        guard let base = URL(string: url.trimmingCharacters(in: .whitespaces)), base.scheme != nil, base.host() != nil else {
            urlInvalid = true
            return
        }
        urlInvalid = false
        guard base != account.endpoint.baseURL else { return }
        var changed = account
        changed.endpoint.baseURL = base
        settings.upsert(changed)
    }

    /// On Return or Save Key, never by leaving the field; an empty field does nothing.
    private func saveKey() {
        guard !key.isEmpty else { return }
        setKey(key)
    }

    private func setKey(_ new: String?) {
        do {
            try settings.setKey(new, for: account.id)
            key = ""
            keyError = nil
        } catch {
            keyError = String(localized: "The key couldn't be saved in the Keychain.")
        }
    }

    /// `/v1/models`, or Anthropic's list.
    static func listModels(_ account: AIAccount, _ settings: ModelSettings) async throws -> [String] {
        let client = try settings.client(for: account, model: "")
        if let openAI = client as? OpenAICompatibleClient { return try await openAI.listModels() }
        if let anthropic = client as? AnthropicClient { return try await anthropic.listModels() }
        return []
    }
}

/// A plan's page (ADR-0024): its state, Codex's switch, Models (never empty), Used by, Test,
/// Usage, and the caption and privacy link. While the CLI isn't installed, only the state, how to
/// install, Usage and the link.
struct PlanPage: View {
    let model: AppModel
    let kind: PlanKind
    @State private var allowFileReads = false

    private var settings: ModelSettings { model.modelSettings }
    private var installed: Bool { settings.executables[kind] != nil }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Text(kind.name).font(.title3.weight(.semibold))
                    LocalityPill(locality: .cloud)
                }
                Text(settings.subscriptionStatus[kind].map { ProviderText.planState($0, kind) } ?? String(localized: "Checking…"))
                    .font(.callout).foregroundStyle(.secondary)
                if !installed, settings.subscriptionStatus[kind] != nil {
                    Text(String(localized: "Install \(kind.tool) and sign in to use your \(kind.plan) plan."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if installed {
                if kind == .codex {
                    Section {
                        Toggle(String(localized: "Use Codex even though it can read files on this Mac"), isOn: $allowFileReads)
                            .onChange(of: allowFileReads) { _, on in
                                guard on != settings.codexAllowsFileReads else { return }
                                settings.codexAllowsFileReads = on
                                Task { await settings.refreshSubscriptions() }
                            }
                        WarningLabel(text: String(localized: "Codex can run commands that read files on this Mac. Funes runs it in an empty folder, read-only, with no internet, and discards any run that uses a command, but it can't switch this ability off. Use it only if you accept that."))
                    }
                }
                ModelListSection(model: model, id: kind.rawValue, load: nil,
                                 caption: String(localized: "Your plan decides which models you can use."))
                UsedBySection(model: model, id: kind.rawValue)
                TestSection(model: model, id: kind.rawValue)
            }
            UsageSection(model: model, id: kind.rawValue)
            Section {
                Text(kind == .claudeCode
                     ? String(localized: "Uses your plan's limits, through the Claude Code you installed and signed in to. Funes never sees your sign-in. Your account's training setting applies.")
                     : String(localized: "Uses your plan's limits, through the Codex you installed and signed in to. Funes never sees your sign-in. Your account's training setting applies."))
                    .font(.callout).foregroundStyle(.secondary)
                Link(String(localized: "\(kind.plan) Privacy Settings"), destination: kind.privacySettings).font(.callout)
            }
        }
        .formStyle(.grouped)
        .onAppear { allowFileReads = settings.codexAllowsFileReads }
        .aiSettingsRefresh(model)
    }
}

/// Add Account (today's add sheet): name, base URL, API key, cloud flag, a first model with Load
/// Models, Test Connection. Add saves and opens the new account's page.
struct AddAccountSheet: View {
    let model: AppModel
    @State var account: AIAccount
    var added: (AIAccount) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var url = ""
    @State private var firstModel = ""
    @State private var models: [String] = []
    @State private var status: String?
    @State private var testing = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Add \(account.name)")).font(.title3.weight(.semibold))
            Form {
                TextField(String(localized: "Name"), text: $account.name)
                TextField(String(localized: "Base URL"), text: $url)
                SecureField(String(localized: "API key"), text: $key, prompt: Text(String(localized: "Stored in the Keychain")))
                if account.endpoint.kind == .openAICompatible {
                    Toggle(String(localized: "It's a cloud service"), isOn: $account.endpoint.markedCloud)
                    Text(String(localized: "Funes treats any server that isn't on this Mac or your local network as cloud, whatever this says."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField(String(localized: "Model"), text: $firstModel)
                    if !models.isEmpty {
                        Menu(String(localized: "Choose")) {
                            ForEach(models, id: \.self) { name in Button(name) { firstModel = name } }
                        }
                        .fixedSize()
                    }
                    Button(String(localized: "Load Models")) { loadModels() }
                }
                Text(EmbeddingCatalog.isEmbeddingModel(firstModel)
                    ? String(localized: "\(firstModel) is an embedding model: it can't propose fields or split memories. Choose it in Features ▸ Search index instead, and put a chat model here, or leave this empty.")
                    : String(localized: "A chat model for New memories, the tidy-up and search answers; add more on the account's page. Embedding models are chosen in Features ▸ Search index; leave this empty if you only use this account for embeddings."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Button(testing ? String(localized: "Testing…") : String(localized: "Test Connection")) { test() }
                    .disabled(testing || firstModel.trimmingCharacters(in: .whitespaces).isEmpty)
                if let status { Text(status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Text(String(localized: "Test Connection classifies one made-up note among Funes's built-in categories; none of your memories or category names are sent."))
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Add")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(account.name.trimmingCharacters(in: .whitespaces).isEmpty || URL(string: url) == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            url = account.endpoint.baseURL.absoluteString
            firstModel = account.models.first ?? ""
        }
    }

    /// The account as typed, and its key.
    private func draft() throws -> (AIAccount, String?) {
        guard let base = URL(string: url.trimmingCharacters(in: .whitespaces)), base.scheme != nil else {
            throw ProviderError.unavailable
        }
        var draft = account
        draft.endpoint.baseURL = base
        let model = firstModel.trimmingCharacters(in: .whitespaces)
        draft.models = model.isEmpty ? [] : [model]
        return (draft, key.isEmpty ? nil : key)
    }

    private func loadModels() {
        status = nil
        Task {
            do {
                let (draft, key) = try draft()
                let client = try ModelSettings.client(for: draft, model: "", key: key)
                if let openAI = client as? OpenAICompatibleClient {
                    models = try await openAI.listModels()
                } else if let anthropic = client as? AnthropicClient {
                    models = try await anthropic.listModels()
                }
                status = models.isEmpty ? String(localized: "The server listed no models.") : String(localized: "\(models.count) models")
            } catch {
                status = ProviderText.error(error)
            }
        }
    }

    private func test() {
        testing = true
        status = nil
        Task {
            defer { testing = false }
            let name = firstModel.trimmingCharacters(in: .whitespaces)
            do {
                let (draft, key) = try draft()
                let started = Date()
                let proposal = try await ModelRouter.testConnection(try ModelSettings.client(for: draft, model: name, key: key))
                let seconds = Date().timeIntervalSince(started).formatted(.number.precision(.fractionLength(1)))
                status = String(localized: "\(name) works: it proposed “\(proposal.title)” in \(seconds) s.")
            } catch ProviderError.server(status: 400) {
                status = EmbeddingCatalog.isEmbeddingModel(name)
                    ? String(localized: "\(name) is an embedding model, so it can't answer chat requests. Choose it in Features ▸ Search index, and test a chat model here.")
                    : String(localized: "The provider refused the request (400). Check that \(name) is a chat model the provider has.")
            } catch {
                status = ProviderText.error(error)
            }
        }
    }

    private func save() {
        do {
            let (draft, key) = try draft()
            if let key { try model.modelSettings.setKey(key, for: draft.id) }
            model.modelSettings.upsert(draft)
            dismiss()
            added(draft)
        } catch {
            self.error = String(localized: "The key couldn't be saved in the Keychain.")
        }
    }
}
