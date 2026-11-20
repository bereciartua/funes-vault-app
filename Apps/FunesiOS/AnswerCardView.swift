import FunesPhone
import FunesProtocol
import SwiftUI

/// Settings ▸ Search answers' stored switch.
enum SearchAnswersSettings {
    static let showAskKey = "searchAnswers.showAsk"
}

/// A memory an answer cites, with the quote to highlight when it opens.
struct AnswerSource: Hashable {
    let id: UUID
    let quote: String
}

/// "✦ Ask Funes", under the search field once results load (UX: iPhone ▸ Search, FR-iOS-13).
struct AskPill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Ask Funes", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .accessibilityHint(Text("Answers this search from its top results, quoting your memories."))
    }
}

/// A numbered source, on a claim and on the cited row.
struct SourceNumber: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.caption2.weight(.semibold)).monospacedDigit()
            .foregroundStyle(Color.accentColor)
            .frame(minWidth: 18, minHeight: 18)
            .background(Circle().fill(Color.accentColor.opacity(0.15)))
    }
}

/// **Not <name>** and **Not this**, one button per target the Mac sent, labelled as the Mac labels them. Not this
/// rejects the fact for every memory, and its undo is on the Mac, so it asks first; a kind this build doesn't know isn't
/// shown.
struct FactsCorrectionButtons: View {
    let targets: [FactsCorrectionTarget]
    let correct: (FactsCorrectionTarget) -> Void
    @State private var confirming: FactsCorrectionTarget?

    var body: some View {
        ForEach(targets.filter { $0.what == .name || $0.what == .fact }, id: \.self) { t in
            Button(t.label ?? String(localized: "Not this"), role: t.what == .name ? nil : .destructive) {
                if t.what == .fact { confirming = t } else { correct(t) }
            }
        }
        .confirmationDialog(String(localized: "Mark this as wrong for every memory?"),
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { t in
            Button(t.label ?? String(localized: "Not this"), role: .destructive) { correct(t) }
        } message: { _ in
            Text("Funes stops using it for every memory. You can undo it on your Mac.")
        }
    }
}

/// What an inferred claim rests on that its quote doesn't say, and its corrections (UX: iPhone ▸ Search, v0.10).
struct InferredSheet: View {
    let claim: MemoryAnswerResult.Claim
    let correct: (FactsCorrectionTarget) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section { Text(claim.text) }
                if let why = claim.why { Section("What Funes inferred") { Text(why) } }
                if let targets = claim.corrections, !targets.isEmpty {
                    Section {
                        FactsCorrectionButtons(targets: targets) { t in
                            dismiss()
                            correct(t)
                        }
                    } footer: {
                        Text("A correction tied to a memory corrects only that memory; Not this corrects the fact everywhere.")
                    }
                }
            }
            .navigationTitle(AnswerWording.inferred)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

/// The answer card: Reading N results… with Cancel, the answer as on the Mac, no answer, or a
/// failure. The results stay below.
struct AnswerCardView: View {
    let search: SearchModel
    let model: PhoneModel
    /// A number was tapped: open that memory with its quote.
    let open: (AnswerSource) -> Void
    /// The inferred claim whose sheet is open.
    @State private var inferred: MemoryAnswerResult.Claim?

    var body: some View {
        switch search.answer {
        case .idle:
            EmptyView()
        case let .reading(count):
            HStack(spacing: 8) {
                ProgressView()
                Text(AnswerWording.reading(count)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { search.clearAnswer() }
            }
            .accessibilityElement(children: .combine)
        case let .answered(result, results):
            if result.outcome == .answered {
                answered(result, results: results)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    header(nil)
                    Text(AnswerWording.noAnswer(result.read)).foregroundStyle(.secondary)
                    ForEach(AnswerWording.notes(result), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    Button("Clear") { search.clearAnswer() }.font(.subheadline)
                }
            }
        case let .failed(failure):
            let message = AnswerWording.failure(failure, engine: search.macAnswers?.engine ?? "", unreachable: PhoneModel.vaultMessage(for:))
            VStack(alignment: .leading, spacing: 6) {
                header(nil)
                Label(message.text, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    if message.retry { Button("Try Again") { search.clearAnswer(); Task { await search.ask() } } }
                    Button("Clear") { search.clearAnswer() }
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
            }
        }
    }

    private func header(_ result: MemoryAnswerResult?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
            Text("Answer").font(.headline)
            if let result {
                Text(AnswerWording.badge(result.engine, result.locality))
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
        }
    }

    private func answered(_ result: MemoryAnswerResult, results: Int) -> some View {
        let sources = result.sources
        return VStack(alignment: .leading, spacing: 12) {
            header(result)
            ForEach(Array(result.claims.enumerated()), id: \.offset) { index, claim in
                VStack(alignment: .leading, spacing: 4) {
                    Text(claim.text).fontWeight(index == 0 ? .semibold : .regular)
                    HStack(spacing: 6) {
                        if claim.inferred == true {
                            // The Mac marked it: what it rests on and its corrections are a tap away.
                            Button { inferred = claim } label: {
                                Text(AnswerWording.inferred).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                    .underline(pattern: .dot)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityHint(Text(claim.why ?? ""))
                        }
                        ForEach(claim.citations, id: \.self) { citation in
                            if let number = sources.firstIndex(of: citation.id).map({ $0 + 1 }) {
                                // A button, not a link: a link would make the whole row one tap.
                                Button { open(AnswerSource(id: citation.id, quote: citation.quote)) } label: {
                                    SourceNumber(number: number)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(Text("Source \(number): \(title(citation.id))"))
                            }
                        }
                    }
                    if let quote = claim.citations.first?.quote {
                        Text("“\(quote)”").font(.footnote).italic().foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .accessibilityElement(children: .contain)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let note = result.note { Text(note) }
                Text(AnswerWording.footer(result, results: results))
                ForEach(AnswerWording.notes(result), id: \.self) { Text($0) }
            }
            .font(.caption).foregroundStyle(.secondary)
            Button("Clear") { search.clearAnswer() }.font(.subheadline).buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .sheet(item: Binding(get: { inferred.map(InferredClaim.init) }, set: { inferred = $0?.claim })) { item in
            InferredSheet(claim: item.claim) { target in Task { await search.correct(target) } }
        }
    }

    /// A claim as a sheet's item.
    private struct InferredClaim: Identifiable {
        let claim: MemoryAnswerResult.Claim
        var id: Int { claim.hashValue }
    }

    private func title(_ id: UUID) -> String { search.results.first { $0.id == id }?.title ?? "" }
}
