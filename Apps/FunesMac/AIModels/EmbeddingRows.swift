import FunesCore
import FunesProtocol
import SwiftUI

/// Settings ▸ AI Models ▸ Embeddings (model providers §4, §7–8; FR-AI-09, FR-AI-11): the bundled
/// bge-small, always on; optionally a provider model as a second index, with its progress, Cancel,
/// Calibrate… for a model Funes hasn't measured, and for a cloud model the agent-request switch
/// and the disclosure line.
struct EmbeddingRows: View {
    let model: AppModel
    @State private var providerID: String?
    @State private var modelName = ""
    @State private var models: [String] = []
    @State private var preparing = false
    @State private var plan: EmbeddingController.Plan?
    @State private var message: String?
    @State private var confirmCalibrate = false
    @State private var confirmRemove = false

    private var settings: ModelSettings { model.modelSettings }
    private var controller: EmbeddingController { model.embeddings }

    var body: some View {
        LabeledContent(String(localized: "Embeddings")) {
            HStack(spacing: 6) {
                Text(String(localized: "Built in (bge-small, on this Mac)")).fixedSize()
                Pill(label: Locality.onDevice.title, tone: .good)
            }
        }
        LabeledContent(String(localized: "Status")) {
            Text(model.services.hasEmbeddings ? String(localized: "Ready") : String(localized: "Unavailable: keyword search only"))
        }
        if let choice = settings.embedding {
            active(choice)
        } else {
            chooser
        }
    }

    // MARK: No provider model yet

    @ViewBuilder
    private var chooser: some View {
        LabeledContent(String(localized: "Provider model")) {
            Picker(String(localized: "Provider model"), selection: $providerID) {
                Text(String(localized: "None")).tag(String?.none)
                ForEach(settings.embeddingProviders) { provider in
                    Text(provider.name).tag(Optional(provider.id))
                }
            }
            .labelsHidden().fixedSize()
            .onChange(of: providerID) { _, _ in
                models = []
                message = nil
                modelName = suggestions.first ?? ""
            }
        }
        .alert(planTitle, isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan = nil } }), presenting: plan) { plan in
            Button(String(localized: "Embed")) {
                settings.setEmbedding(plan.choice)
                providerID = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { plan in
            Text(planMessage(plan))
        }
        if providerID != nil {
            HStack {
                TextField(String(localized: "Model"), text: $modelName)
                Menu(String(localized: "Choose")) {
                    ForEach(suggestions, id: \.self) { name in Button(name) { modelName = name } }
                    if !models.isEmpty {
                        Divider()
                        ForEach(models, id: \.self) { name in Button(name) { modelName = name } }
                    }
                }
                .fixedSize()
                Button(String(localized: "Load Models")) { loadModels() }
                Button(preparing ? String(localized: "Checking…") : String(localized: "Use…")) { prepare() }
                    .disabled(preparing || modelName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        Text(settings.embeddingProviders.isEmpty
            ? String(localized: "Optional: a provider's embedding model as a second index next to bge-small, mainly for tasks without keywords and for other languages. Add Ollama, LM Studio or OpenAI under Providers first.")
            : String(localized: "Optional: a provider's embedding model as a second index next to bge-small, mainly for tasks without keywords and for other languages. Funes has measured Qwen3-Embedding-0.6B (Ollama, LM Studio) and OpenAI's text-embedding-3. Memories above the cloud limit keep bge-small only."))
            .font(.callout).foregroundStyle(.secondary)
        if let message { Text(message).font(.callout).foregroundStyle(.red) }
    }

    private var chosenProvider: ProviderConfig? { providerID.flatMap { id in settings.providers.first { $0.id == id } } }

    private var suggestions: [String] {
        guard let provider = chosenProvider else { return [] }
        // Only a literal local address or localhost counts here: no DNS lookup on the main thread.
        let local = !provider.endpoint.markedCloud
            && LocalityDetector.isLocal(host: provider.endpoint.baseURL.host() ?? "", resolve: { _ in [] })
        return EmbeddingCatalog.suggestions(cloud: !local)
    }

    private var planTitle: String {
        guard let plan else { return "" }
        return String(localized: "Embed \(plan.memories) memories with \(plan.choice.model)?")
    }

    private func planMessage(_ plan: EmbeddingController.Plan) -> String {
        let name = settings.providers.first { $0.id == plan.choice.provider }?.name ?? plan.choice.provider
        var lines = [plan.locality.isLocal
            ? String(localized: "\(name) runs on this Mac or your local network, so every memory is embedded and nothing leaves it.")
            : String(localized: "About \(plan.tokens) tokens go to \(name). Memories above \(ModelSettingsPane.title(settings.cloudLimit)) stay on this Mac's index only.")]
        lines.append(String(localized: "Search keeps using bge-small until it's done; you can cancel any time."))
        if !plan.calibrated {
            lines.append(String(localized: "Funes hasn't measured this model, so search keeps its 10 closest matches until you calibrate it."))
        }
        return lines.joined(separator: " ")
    }

    private func loadModels() {
        guard let provider = chosenProvider else { return }
        message = nil
        Task {
            do {
                guard let client = try settings.client(for: provider) as? OpenAICompatibleClient else { return }
                models = try await client.listModels()
            } catch {
                message = ProviderSheet.text(error)
            }
        }
    }

    private func prepare() {
        guard let provider = chosenProvider else { return }
        preparing = true
        message = nil
        Task {
            defer { preparing = false }
            do {
                plan = try await controller.prepare(EmbeddingChoice(provider: provider.id,
                                                                    model: modelName.trimmingCharacters(in: .whitespaces)))
            } catch {
                message = ProviderError.invalidOutput == error as? ProviderError
                    ? String(localized: "That model didn't return usable vectors. Check it's an embedding model.")
                    : ProviderSheet.text(error)
            }
        }
    }

    // MARK: With a provider model

    @ViewBuilder
    private func active(_ choice: EmbeddingChoice) -> some View {
        let name = settings.embeddingProvider?.name ?? choice.provider
        LabeledContent(String(localized: "Provider model")) {
            HStack(spacing: 6) {
                Text("\(name) · \(choice.model)").fixedSize()
                if let locality = controller.locality {
                    Pill(label: locality.title, tone: locality.isLocal ? .good : .warning)
                }
            }
        }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(status(choice)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if case .failed? = controller.progress?.state {
                Button(String(localized: "Retry")) { controller.retryNow() }
            } else if !controller.isComplete, controller.problem == nil {
                Button(String(localized: "Cancel")) { confirmRemove = true }
            }
        }
        if let info = controller.model, !info.isCalibrated {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "Funes hasn't measured this model, so search keeps its 10 closest matches. Calibrate measures where its matches start with Funes's made-up benchmark."))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(controller.calibrating ? String(localized: "Calibrating…") : String(localized: "Calibrate…")) { confirmCalibrate = true }
                    .disabled(controller.calibrating)
            }
        }
        if let locality = controller.locality, !locality.isLocal {
            Toggle(String(localized: "Embed agent requests with the cloud model"),
                   isOn: Binding(get: { choice.embedsAgentTasks }, set: { settings.setEmbedsAgentTasks($0) }))
            WarningLabel(text: disclosure(choice, provider: name), symbol: "arrow.up.forward.app")
        }
        HStack {
            Spacer()
            Button(String(localized: "Stop Using \(choice.model)…"), role: .destructive) { confirmRemove = true }
        }
        .confirmationDialog(String(localized: "Stop using \(choice.model)?"), isPresented: $confirmRemove) {
            Button(String(localized: "Stop Using It"), role: .destructive) { controller.remove() }
        } message: {
            Text(String(localized: "Its vectors are deleted and search uses bge-small alone."))
        }
        .confirmationDialog(String(localized: "Calibrate \(choice.model)?"), isPresented: $confirmCalibrate) {
            Button(String(localized: "Calibrate")) {
                Task {
                    do { try await controller.calibrate() } catch { message = ProviderSheet.text(error) }
                }
            }
        } message: {
            Text(String(localized: "Funes sends its 230 made-up benchmark texts, none of your memories, to \(name): about 7,000 tokens."))
        }
        if let message { Text(message).font(.callout).foregroundStyle(.red) }
    }

    /// "Embedding 1,240 of 3,000", "Ready", "Unavailable: check the API key"… (model providers §4)
    private func status(_ choice: EmbeddingChoice) -> String {
        if let problem = controller.problem {
            return ProviderSheet.text(problem) + " " + String(localized: "Search uses bge-small.")
        }
        guard let p = controller.progress else { return String(localized: "Starting…") }
        switch p.state {
        case .idle:
            return String(localized: "Starting…")
        case .running:
            return controller.isComplete
                ? String(localized: "Updating: \(p.done) of \(p.total)")
                : String(localized: "Embedding \(p.done) of \(p.total). Search uses bge-small until it's done.")
        case let .waiting(until):
            return String(localized: "The provider asked to slow down; continuing at \(until.formatted(date: .omitted, time: .shortened)).")
        case let .failed(error):
            return ProviderSheet.text(error) + " " + String(localized: "Search uses bge-small meanwhile.")
        case .complete:
            if controller.locality?.isLocal == false {
                return String(localized: "Ready: \(p.total) memories use \(choice.model); those above \(ModelSettingsPane.title(settings.cloudLimit)) use bge-small.")
            }
            return String(localized: "Ready: \(p.total) memories use \(choice.model).")
        }
    }

    /// "Search embeddings send memory text (up to Internal), your searches and agents' task
    /// descriptions to OpenAI." (FR-AI-08, FR-AI-09)
    private func disclosure(_ choice: EmbeddingChoice, provider: String) -> String {
        switch settings.cloudLimit {
        case .never:
            return choice.embedsAgentTasks
                ? String(localized: "Search embeddings send your searches and agents' task descriptions to \(provider), but no memory text: the cloud limit is Nothing.")
                : String(localized: "Search embeddings send your searches to \(provider), but no memory text: the cloud limit is Nothing.")
        case let .upTo(level):
            let limit = ModelSettingsPane.title(.upTo(level))
            return choice.embedsAgentTasks
                ? String(localized: "Search embeddings send memory text (up to \(limit)), your searches and agents' task descriptions to \(provider).")
                : String(localized: "Search embeddings send memory text (up to \(limit)) and your searches to \(provider). Agents' requests are matched on this Mac.")
        }
    }
}
