import FunesCore
import FunesProtocol
import os
import SwiftUI

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "facts")

/// The backfill sheet (FR-F-03, 04-ux-mac.md ▸ Page: Facts): the call count and cost first, computed from the open vault
/// for the model Facts would use now; nothing is sent before **Start Reading**. The same sheet carries on a backfill a
/// change of model or cloud limit paused (**Continue Reading**).
struct FactsBackfillSheet: View {
    enum Mode { case start, review }

    let model: AppModel
    let mode: Mode
    /// Opened by turning Learn from memories on: closes itself when there's nothing to send.
    var automatic = false
    /// The UI review's sample count (no vault is counted then).
    var preset: FactsBackfill.Estimate?
    @Binding var shown: Bool
    @State private var estimate: FactsBackfill.Estimate?
    @State private var extractor: FactsExtractor?
    @State private var working = false
    @State private var failed = false
    @State private var noModel = false

    private var text: AIJobText { AIJobText(model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .start ? String(localized: "Read your existing memories?") : String(localized: "Carry on reading your memories?"))
                .font(.headline)
            if let estimate {
                ForEach(text.backfillLines(estimate), id: \.self) { line in
                    Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            } else if noModel {
                Text(text.problemStatus).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if failed {
                Text(String(localized: "Funes couldn't count your memories. Try again.")).font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Counting your memories…")).font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                Spacer()
                Button(String(localized: "Not Now")) { shown = false }.keyboardShortcut(.cancelAction)
                // A review carries on even with nothing left to send: the reads owed end without a request.
                if let estimate, estimate.calls > 0 || mode == .review {
                    Button(mode == .start ? String(localized: "Start Reading") : String(localized: "Continue Reading"), action: go)
                        .keyboardShortcut(.defaultAction)
                        .disabled(working)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await count() }
    }

    private func count() async {
        if let preset {
            estimate = preset
            return
        }
        guard let x = await model.processing.factsExtractor() else {
            // No model resolves now (the status line says why): nothing can be counted until one does.
            noModel = true
            return
        }
        do {
            let e = try await model.services.store.factsBackfillEstimate(extractor: x, owed: mode == .review)
            extractor = x
            estimate = e
            if automatic, e.calls == 0 { shown = false }
        } catch {
            logger.error("Counting memories for the facts backfill failed")
            failed = true
        }
    }

    private func go() {
        guard let extractor, let estimate else { return }
        working = true
        let store = model.services.store, activity = model.services.activity
        Task {
            defer { working = false }
            do {
                switch mode {
                case .start: try await store.startFactsBackfill(extractor: extractor, shown: estimate, activity: activity)
                case .review: try await store.reviewFactsBackfill(extractor: extractor, shown: estimate, activity: activity)
                }
                shown = false
                model.processing.kick()
                model.scheduleRefresh()
            } catch FactsBackfill.StartError.changed {
                // The vault or Facts changed since the count: show the new one (nothing was sent).
                self.estimate = nil
                await count()
            } catch {
                logger.error("Starting the facts backfill failed")
                shown = false
                model.scheduleRefresh()
            }
        }
    }
}

extension AIJobText {
    // MARK: The first backfill (FR-F-03)

    /// The sheet's lines, from the estimate: what's sent, to whom, in how many requests, the cost when it's measured,
    /// how long, that it's outside today's cap and happens once, and what stays on this Mac.
    func backfillLines(_ e: FactsBackfill.Estimate) -> [String] {
        let settings = model.modelSettings
        guard e.calls > 0 else {
            return [String(localized: "There's nothing to send: Funes has read every memory it may send, and the rest stay on this Mac.")]
        }
        let account = settings.factsResolution.account
        let plan = account.flatMap(PlanKind.init(rawValue:))
        let to = plan?.plan ?? account.map(settings.name) ?? ""
        let sent = e.memories - e.kept
        let requests = e.calls.formatted()
        var lines: [String] = []
        let each = e.groups.count > 1 ? String(localized: "two for each memory") : String(localized: "one for each memory")
        // "two for each memory" only when it's true (some memories were read already in one group).
        let even = e.calls == sent * e.groups.count
        if case let .upTo(level)? = e.limit {
            let limit = CloudLimitText.title(.upTo(level))
            lines.append(even ? String(localized: "Funes will send \(sent) memories (up to \(limit)) to \(to), in about \(requests) requests: \(each).")
                              : String(localized: "Funes will send \(sent) memories (up to \(limit)) to \(to), in about \(requests) requests."))
        } else {
            lines.append(even ? String(localized: "Funes will read \(sent) memories with \(to), in about \(requests) requests: \(each).")
                              : String(localized: "Funes will read \(sent) memories with \(to), in about \(requests) requests."))
        }
        if let cost = e.cost {
            let amount = cost < 0.01 ? String(localized: "Less than $0.01") : String(localized: "About \(cost.formatted(.currency(code: "USD").precision(.fractionLength(2))))")
            if let plan {
                lines.append(String(localized: "\(amount) at API prices. With your \(plan.plan) plan, it counts toward the plan's limits instead."))
            } else {
                lines.append(String(localized: "\(amount) at API prices."))
            }
        }
        let cap = settings.dailyCap
        if settings.factsLocality?.isLocal == true {
            // A model on this Mac or a local server: nothing counts toward the cloud requests, and its speed is unknown.
            lines.append(String(localized: "It runs while Funes isn't busy. Requests to a local model don't count toward today's cloud requests."))
        } else {
            lines.append(e.calls <= 1_000
                ? String(localized: "It takes under an hour, while Funes isn't busy, and doesn't count toward today's \(cap) cloud requests.")
                : String(localized: "It takes a few hours, while Funes isn't busy, and doesn't count toward today's \(cap) cloud requests."))
            lines.append(String(localized: "This happens once. After it, new and changed memories count as usual."))
        }
        if e.kept > 0, case let .upTo(level)? = e.limit {
            lines.append(String(localized: "\(e.kept) memories above \(CloudLimitText.title(.upTo(level))) stay on this Mac: Funes links them from what it already knows."))
        }
        return lines
    }

    /// The page's backfill line while it runs: progress, paused, or paused by a change.
    var backfillStatus: String? {
        guard let p = model.factsBackfill, p.state.isRunning else { return nil }
        if !model.modelSettings.factsLearn {
            return String(localized: "Reading your memories waits while Learn from memories is off: \(p.done) of \(p.total) read.")
        }
        if p.state.changed {
            return String(localized: "Paused: Facts' model or the cloud limit changed since you started. Review the new count to carry on.")
        }
        if p.state.paused { return String(localized: "Paused: \(p.done) of \(p.total) memories read.") }
        return String(localized: "Reading your memories: \(p.done) of \(p.total)")
    }

    /// Facts jobs waiting for tomorrow's cap: the whole cap, or low-priority work's share and the agents' share (both
    /// can wait at once).
    var factsCapStatus: String? {
        let wait = model.factsCapWait, cap = model.modelSettings.dailyCap
        if wait.contains(.total) {
            return String(localized: "Waiting: today's \(cap) cloud requests are used up. Funes carries on tomorrow.")
        }
        var lines: [String] = []
        if wait.contains(.lowPriority) {
            let share = CloudRequestCap.lowPriorityLimit(for: cap)
            lines.append(String(localized: "Waiting: catching up on older memories can use \(share) of today's \(cap) cloud requests, and it has. New and changed memories are still read; the rest carries on tomorrow."))
        }
        if wait.contains(.agents) {
            lines.append(String(localized: "Waiting: agents' share of today's cloud requests is used up. Memories agents wrote are read tomorrow."))
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// Why Read Existing Memories… can't open now (its help), or nil when it can.
    var backfillUnavailable: String? {
        let settings = model.modelSettings
        if settings.factsProblem != nil { return problemStatus }
        if !settings.factsLearn { return String(localized: "Turn on Learn from memories first.") }
        return nil
    }

    /// Remove's message. Remove starts Facts over: turning learning on again offers the backfill sheet, as the first time.
    var removeMessage: String {
        String(localized: "The facts and corrections you entered yourself stay. Learning turns off; turning it on again offers to read your memories again.")
    }
}
