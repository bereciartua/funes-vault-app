import FunesCore
import FunesProtocol
import SwiftUI

/// Settings ▸ AI Models (04-ux-mac.md, model-providers.md §4, FR-AI-05..08, FR-AI-12). v0.1's
/// embeddings are the bundled bge-small only (ADR-0016): shown, with nothing to choose.
struct ModelSettingsPane: View {
    let model: AppModel
    @State private var editing: ProviderConfig?
    @State private var adding: ProviderConfig?
    @State private var localities: [String: Locality] = [:]

    private var settings: ModelSettings { model.modelSettings }

    var body: some View {
        Form {
            Section(String(localized: "Tasks")) {
                LabeledContent(String(localized: "Embeddings")) {
                    Text(String(localized: "Built in (bge-small, on this Mac)")).fixedSize()
                }
                LabeledContent(String(localized: "Status")) {
                    HStack(spacing: 6) {
                        Text(model.services.hasEmbeddings ? String(localized: "Ready")
                                                          : String(localized: "Unavailable: keyword search only"))
                        Pill(label: Locality.onDevice.title, tone: .good)
                    }
                }
                Text(String(localized: "Search and agents' requests are matched on this Mac. Other embedding models come in a later version."))
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent(String(localized: "Classification")) {
                    HStack(spacing: 6) {
                        Picker(String(localized: "Classification"), selection: Binding(get: { settings.classifierID },
                                                                                      set: { settings.setClassifier($0) })) {
                            Text(String(localized: "Apple on-device")).tag(String?.none)
                            ForEach(settings.providers) { provider in
                                Text("\(provider.name) · \(provider.model.isEmpty ? String(localized: "no model") : provider.model)")
                                    .tag(Optional(provider.id))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Pill(label: classifierLocality.title, tone: classifierLocality.isLocal ? .good : .warning)
                    }
                }
                Text(classificationStatus).font(.callout).foregroundStyle(.secondary)
                if let disclosure = classificationDisclosure {
                    Label(disclosure, systemImage: "arrow.up.forward.app")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section(String(localized: "Cloud limit")) {
                Picker(String(localized: "Never send captures above"), selection: Binding(get: { settings.cloudLimit },
                                                                                          set: { settings.cloudLimit = $0 })) {
                    ForEach([Sensitivity.public, .low, .internal, .sensitive], id: \.self) { level in
                        Text(level.title).tag(CloudLimit.upTo(level))
                    }
                    Divider()
                    Text(String(localized: "Never send captures")).tag(CloudLimit.never)
                }
                Text(String(localized: "Applies to every cloud provider. Captures are checked on this Mac first, and anything that looks like a secret is never sent."))
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
    }

    private var classifierLocality: Locality {
        guard let provider = settings.classifier else { return .onDevice }
        return localities[provider.id] ?? (provider.endpoint.markedCloud ? .cloud : .localServer)
    }

    private var classificationStatus: String {
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

    /// "Classification sends new captures (up to Internal) and your category names and descriptions to
    /// Anthropic." (FR-AI-08) Only captures are classified in v0.1.
    private var classificationDisclosure: String? {
        guard let provider = settings.classifier, !classifierLocality.isLocal else { return nil }
        switch settings.cloudLimit {
        case .never:
            return String(localized: "Classification sends nothing to \(provider.name): the cloud limit is Never send captures, so it runs on this Mac.")
        case .upTo(let level):
            return String(localized: "Classification sends new captures (up to \(level.title)) and your category names and descriptions to \(provider.name).")
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
        case .transport?, nil: String(localized: "Couldn't reach the server.")
        }
    }
}
