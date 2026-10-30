import AppKit
import FunesCore
import FunesProtocol
import SwiftUI

/// The Vault's Search answers row (04-ux-mac.md ▸ Vault, FR-AI-17): "Ask Funes" with ⌘⏎, then the
/// reading card with Cancel, then the answer, no answer or a failure. Rows below never move.
struct AnswerCard: View {
    let vault: VaultModel
    let model: AppModel

    var body: some View {
        Group {
            switch vault.answer {
            case nil:
                askRow
            case let .reading(count):
                reading(count)
            case let .answered(answer, results, engine, limit):
                if answer.outcome == .answered {
                    answered(answer, results: results, engine: engine, limit: limit)
                } else {
                    noAnswer(answer, limit: limit)
                }
            case let .failed(text, retry):
                failed(text, retry: retry)
            }
        }
        .padding(.vertical, 6)
    }

    private var askRow: some View {
        Button { vault.ask() } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                Text(String(localized: "Ask Funes")).fontWeight(.medium)
                Spacer()
                Text("⌘⏎").font(.callout).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Answer this search from its top results"))
        .accessibilityHint(String(localized: "Answers this search from its top results, quoting your memories."))
    }

    private func reading(_ count: Int) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(String(localized: "Reading \(count) results…")).foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "Cancel")) { vault.clearAnswer() }
        }
        .accessibilityElement(children: .combine)
    }

    private func header(_ answer: SearchAnswer?, engine: String = "") -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
            Text(String(localized: "Answer")).fontWeight(.semibold)
            if let answer, let locality = answer.locality {
                Pill(label: locality == .onDevice ? locality.title : "\(engine) · \(locality.title)",
                     tone: locality.isLocal ? .good : .warning)
            }
            Spacer()
        }
    }

    private func answered(_ answer: SearchAnswer, results: Int, engine: String, limit: String) -> some View {
        let sources = vault.answerSources
        return VStack(alignment: .leading, spacing: 10) {
            header(answer, engine: engine)
            ForEach(Array(answer.claims.enumerated()), id: \.offset) { index, claim in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(claim.text).fontWeight(index == 0 ? .semibold : .regular)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        ForEach(claim.citations, id: \.self) { citation in
                            if let number = sources.firstIndex(of: citation.memoryID).map({ $0 + 1 }) {
                                SourceChip(number: number) { vault.showSource(citation.memoryID, quote: citation.quote) }
                                    .help(title(citation.memoryID))
                                    .accessibilityLabel(String(localized: "Source \(number): \(title(citation.memoryID))"))
                            }
                        }
                    }
                    if let quote = claim.citations.first?.quote {
                        Text("“\(quote)”")
                            .font(.callout).italic().foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                            .padding(.leading, 8)
                            .overlay(alignment: .leading) { Rectangle().fill(Palette.separator).frame(width: 2) }
                            .help(quote)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            footer(answer, results: results, limit: limit)
            HStack {
                Button(String(localized: "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer.claims.map(\.text).joined(separator: "\n"), forType: .string)
                }
                Button(String(localized: "Clear")) { vault.clearAnswer() }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.25)))
    }

    private func noAnswer(_ answer: SearchAnswer, limit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(nil)
            Text(String(localized: "No answer in the \(answer.read) results read.")).foregroundStyle(.secondary)
            ForEach(Self.notes(answer, limit: limit), id: \.self) {
                Text($0).font(.caption).foregroundStyle(.secondary)
            }
            Button(String(localized: "Clear")) { vault.clearAnswer() }.controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.card))
    }

    private func failed(_ text: String, retry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(nil)
            Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            HStack {
                if retry { Button(String(localized: "Try Again")) { vault.ask() } }
                Button(String(localized: "Clear")) { vault.clearAnswer() }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.card))
    }

    private func footer(_ answer: SearchAnswer, results: Int, limit: String) -> some View {
        let seconds = Int((Double(answer.duration.components.seconds) + Double(answer.duration.components.attoseconds) / 1e18).rounded())
        return VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "Read \(answer.read) of \(results) results · \(seconds) s"))
            ForEach(Self.notes(answer, limit: limit), id: \.self) { Text($0) }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    /// "1 memory above Internal wasn't read", "1 claim left out: it didn't quote a memory".
    static func notes(_ answer: SearchAnswer, limit: String) -> [String] {
        var lines: [String] = []
        switch answer.withheld {
        case 0: break
        case 1: lines.append(String(localized: "1 memory above \(limit) wasn't read"))
        default: lines.append(String(localized: "\(answer.withheld) memories above \(limit) weren't read"))
        }
        switch answer.dropped {
        case 0: break
        case 1: lines.append(String(localized: "1 claim left out: it didn't quote a memory"))
        default: lines.append(String(localized: "\(answer.dropped) claims left out: they didn't quote a memory"))
        }
        return lines
    }

    private func title(_ id: UUID) -> String { vault.memories.first { $0.id == id }?.title ?? "" }
}

/// A numbered source chip, on the card's claims and on the cited rows.
struct SourceChip: View {
    let number: Int
    var action: (() -> Void)?

    var body: some View {
        let chip = Text("\(number)")
            .font(.caption2.weight(.semibold)).monospacedDigit()
            .foregroundStyle(Color.accentColor)
            .frame(minWidth: 16, minHeight: 16)
            .background(Circle().fill(Color.accentColor.opacity(0.15)))
        if let action {
            Button(action: action) { chip }.buttonStyle(.plain)
        } else {
            chip
        }
    }
}
