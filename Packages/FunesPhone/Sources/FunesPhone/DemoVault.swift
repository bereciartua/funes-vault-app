import Foundation
import FunesProtocol
import os
import Synchronization

private let logger = Logger(subsystem: Identifiers.iOSLoggerSubsystem, category: "demo")

/// The demo vault (FR-iOS-10, task 5.7): a sample vault on this iPhone only, for App Review, who
/// have no Mac to pair with, and for trying the app first. It answers the companion methods as
/// the Mac does, behind the same `CompanionCalling` and `CaptureSender` that `CompanionClient`
/// serves, from the bundled `demo-vault.json`: about 25 memories, seven Inbox suggestions (four
/// of them the daily tidy-up's: an archive, a merge, a conflict and a split), one Share, Save
/// and access request each, and 12 weeks of sample counts for the overview (Home and
/// the widgets).
///
/// Nothing here reaches the network, the Keychain, CloudKit or the real capture queue. Changes
/// live in memory only, so each demo starts from the bundled data again.
public final class DemoVault: CompanionCalling, CaptureSender {
    /// Where the demo "Mac" is. `.invalid` never resolves (RFC 2606), and nothing connects to it:
    /// it only fills `MacConnection` for the reachability state.
    public static let address = MacAddress(kind: .lan, base: URL(string: "http://demo.invalid")!)
    /// How Inbox rows from demo captures are labelled.
    public static let captureLabel = "Demo capture"
    /// A demo request is always 14 minutes from its end, so it never expires under App Review.
    static let requestLifetime: TimeInterval = 14 * 60
    static let revision = "demo"

    struct State: Sendable {
        var macName: String
        var categories: [CompanionCategory]
        var memories: [UUID: Memory]
        var provenance: [UUID: [ProvenanceLabel]]
        var shared: [UUID: (count: Int, last: Date?)]
        var inbox: [InboxItem]
        /// What `inbox.get` adds to a card: its memories, the tidy-up's reasons, a split's pieces.
        var cards: [UUID: Card] = [:]
        var approvals: [DemoContent.Approval]
        var approvalIDs: [UUID]
        var approvalsEnabled = true
        /// Capture ids already taken, so a resend counts as accepted without a second row (§6).
        var captured: Set<UUID> = []
        var overview: DemoContent.Overview?
        /// The sample agents' ids, made up when the demo opens.
        var overviewAgentIDs: [UUID] = []
        /// The demo person's name, for Home's title (ADR-0026).
        var calledName: String?
        var calendar: Calendar = .autoupdatingCurrent
    }

    struct Card: Sendable {
        /// Each memory with the version the card was made on, as the Mac stores it.
        var refs: [(id: UUID, role: InboxMemoryRole, version: Int)] = []
        var tidyUp: InboxTidyUp?
        var pieces: [InboxItem] = []
    }

    private let state: Mutex<State>
    private let clock: @Sendable () -> Date

    /// The bundled demo vault. `content` replaces it in tests, and `calendar` the phone's days.
    public init(content: DemoContent? = nil, calendar: Calendar = .autoupdatingCurrent, clock: @escaping @Sendable () -> Date = Date.init) {
        self.clock = clock
        let content = content ?? Self.bundled()
        var state = Self.state(from: content, now: clock())
        state.calendar = calendar
        self.state = Mutex(state)
    }

    static func bundled() -> DemoContent {
        do {
            guard let url = Bundle.module.url(forResource: "demo-vault", withExtension: "json") else { throw CocoaError(.fileNoSuchFile) }
            return try JSONDecoder().decode(DemoContent.self, from: Data(contentsOf: url))
        } catch {
            logger.fault("The bundled demo vault couldn't be read")
            return DemoContent(macName: "Demo Mac", categories: [], memories: [], inbox: [], approvals: [])
        }
    }

    /// `overview.get`'s answer, at once: the widgets' gallery and placeholder entries.
    public func sampleOverview(_ range: OverviewRange = .days30) -> VaultOverview {
        let now = clock()
        return state.withLock { Self.overview(range, in: $0, now: now) }
    }

    /// `status.get`'s answer, for the reachability state: always connected.
    public var connection: MacConnection {
        let status = try? handle(.statusGet, EmptyParams()) as? CompanionStatus
        return MacConnection(address: Self.address, status: status ?? CompanionStatus(macName: "", appVersion: "", serverTime: clock(), inboxPending: 0, vaultActive: true),
                             roundTrip: .zero)
    }

    // MARK: CompanionCalling, CaptureSender

    public func perform<Call: CompanionCall>(_ request: PendingCall<Call>) async throws(CompanionClientError) -> Call.Result {
        try handle(Call.method, request.params) as! Call.Result
    }

    public func submit(_ captures: [CompanionCapture]) async throws(CompanionClientError) -> CapturesSubmitResult {
        try await call(CapturesSubmit.self, CapturesSubmitParams(captures: captures))
    }

    // MARK: The methods

    private func handle(_ method: CompanionMethod, _ params: any Sendable) throws(CompanionClientError) -> any Sendable {
        let now = clock()
        do {
            return try state.withLock { state throws(CompanionError) -> any Sendable in
                try Self.handle(method, params, in: &state, now: now)
            }
        } catch {
            throw .method(error)
        }
    }

    private static func handle(_ method: CompanionMethod, _ params: any Sendable, in state: inout State, now: Date) throws(CompanionError) -> any Sendable {
        switch method {
        case .statusGet:
            return CompanionStatus(macName: state.macName, appVersion: "Demo", serverTime: now, inboxPending: state.inbox.count,
                                   vaultActive: true, calledName: state.calledName,
                                   searchAnswers: SearchAnswersStatus(engine: "Demo", locality: .onDevice))
        case .capturesSubmit:
            let params = params as! CapturesSubmitParams
            try params.validate()
            for capture in params.captures where state.captured.insert(capture.captureId).inserted {
                let text = capture.note.map { capture.text + "\n\n" + $0 } ?? capture.text
                state.inbox.insert(InboxItem(id: UUID(), origin: .captureIPhone, action: .create, sourceLabel: captureLabel,
                                             title: title(for: capture.text), body: text, kind: .fact, categories: [], sensitivity: .low,
                                             createdAt: capture.createdAt), at: 0)
            }
            return CapturesSubmitResult(accepted: params.captures.map(\.captureId), rejected: [])
        case .overviewGet:
            return overview((params as! OverviewParams).range, in: state, now: now)
        case .categoriesList:
            return state.categories
        case .memoriesSearch:
            let params = params as! MemorySearchParams
            try params.validate()
            return search(params, in: state)
        case .memoriesAnswer:
            let params = params as! MemoryAnswerParams
            try params.validate()
            return try answer(params, in: state)
        case .memoriesGet:
            let id = (params as! MemoryID).id
            guard let memory = state.memories[id] else { throw CompanionError(.notFound) }
            let shared = state.shared[id]
            return CompanionMemory(memory: memory, provenance: state.provenance[id] ?? [], sharedCount: shared?.count ?? 0,
                                   lastSharedAt: shared?.last)
        case .memoriesCreate:
            let params = params as! MemoryCreateParams
            let memory = Memory(title: params.title, body: params.body, kind: params.kind, categoryKeys: params.categories,
                                sensitivity: params.sensitivity, expiresAt: params.expiresAt, source: .manual, createdAt: now, updatedAt: now)
            add(memory, event: .created, label: "You", in: &state)
            return MemoryCreated(id: memory.id, version: memory.version)
        case .memoriesUpdate:
            let params = params as! MemoryUpdateParams
            var memory = try current(params.id, version: params.version, in: state)
            apply(params.changes, to: &memory)
            return save(memory, event: .edited, now: now, in: &state)
        case .memoriesArchive, .memoriesRestore, .memoriesDelete:
            let ref = params as! MemoryVersionRef
            var memory = try current(ref.id, version: ref.version, in: state)
            let (status, event): (MemoryStatus, ProvenanceEvent) = switch method {
            case .memoriesArchive: (.archived, .archived)
            case .memoriesRestore: (.active, .restored)
            default: (.deleted, .deleted)
            }
            memory.status = status
            memory.deletedAt = status == .deleted ? now : nil
            return save(memory, event: event, now: now, in: &state)
        case .inboxList:
            let offset = (params as! InboxListParams).cursor.flatMap(Int.init) ?? 0
            let page = Array(state.inbox.dropFirst(offset).prefix(20))
            return InboxListResult(items: page, nextCursor: offset + page.count < state.inbox.count ? String(offset + page.count) : nil)
        case .inboxGet:
            let id = (params as! SuggestionID).suggestionId
            guard let item = state.inbox.first(where: { $0.id == id }) else { throw CompanionError(.notFound) }
            return card(item, in: state)
        case .inboxApply:
            let params = params as! InboxApplyParams
            guard let index = state.inbox.firstIndex(where: { $0.id == params.suggestionId }) else { throw CompanionError(.notFound) }
            let item = state.inbox[index]
            guard item.action.appliesOnPhone else { throw CompanionError(.unsupportedAction) }
            guard item.processing != .processing else { throw CompanionError(.processing) }
            if let revision = params.revision, revision != card(item, in: state).revision { throw CompanionError(.requestChanged) }
            if params.mode != .keepBoth, let card = state.cards[item.id], stale(card, in: state) { throw CompanionError(.targetChanged) }
            let id = try applyCard(item, params, now: now, in: &state)
            state.inbox.remove(at: index)
            state.cards[item.id] = nil
            return InboxApplied(memoryId: id)
        case .inboxReviewAgain:
            let id = (params as! SuggestionID).suggestionId
            guard state.inbox.contains(where: { $0.id == id }), var card = state.cards[id] else { throw CompanionError(.conflict) }
            for index in card.refs.indices {
                guard let memory = state.memories[card.refs[index].id], memory.status == .active else { throw CompanionError(.targetChanged) }
                card.refs[index].version = memory.version
            }
            state.cards[id] = card
            return EmptyResult()
        case .inboxReject:
            let id = (params as! SuggestionID).suggestionId
            guard let index = state.inbox.firstIndex(where: { $0.id == id }) else { throw CompanionError(.notFound) }
            state.inbox.remove(at: index)
            return EmptyResult()
        case .inboxRetry, .inboxKeep:
            let id = (params as! SuggestionID).suggestionId
            guard let index = state.inbox.firstIndex(where: { $0.id == id }) else { throw CompanionError(.notFound) }
            guard state.inbox[index].processing == .failed else { throw CompanionError(.conflict) }
            // The demo never splits: tried again, it comes back as it was.
            state.inbox[index].processing = nil
            return EmptyResult()
        case .deviceUnpair:
            return EmptyResult()
        case .approvalsList:
            let items = state.approvalIDs.indices.map { index in
                let detail = detail(index, in: state, now: now)
                return ApprovalSummary(id: detail.id, kind: detail.kind, agentName: detail.agentName, agentKind: detail.agentKind,
                                       count: detail.share?.rows.count ?? 1, createdAt: detail.createdAt, expiresAt: detail.expiresAt)
            }
            return ApprovalListResult(items: items)
        case .approvalsGet:
            // A ring never comes in the demo: only ids.
            guard let id = (params as! ApprovalRef).id, let index = state.approvalIDs.firstIndex(of: id) else { throw CompanionError(.notFound) }
            return detail(index, in: state, now: now)
        case .approvalsAnswer:
            let params = params as! ApprovalAnswerParams
            try params.validate()
            guard let index = state.approvalIDs.firstIndex(of: params.id) else { throw CompanionError(.alreadyAnswered) }
            let request = detail(index, in: state, now: now)
            let sample = state.approvals[index]
            guard params.revision == request.revision else { throw CompanionError(.requestChanged) }
            guard params.choice.kind == request.kind else { throw CompanionError(.invalidInput, message: "Not this request's choice") }
            state.approvals.remove(at: index)
            state.approvalIDs.remove(at: index)
            var memoryID: UUID?
            if params.choice == .share {
                for id in params.memoryIds ?? [] where state.memories[id] != nil {
                    state.shared[id] = ((state.shared[id]?.count ?? 0) + 1, now)
                    state.provenance[id, default: []].append(ProvenanceLabel(at: now, event: ProvenanceEvent.shared.rawValue, label: request.agentName))
                }
            } else if params.choice == .save, let save = sample.save {
                memoryID = applySuggestion(save.memoryChanges, action: save.action, target: save.targetMemoryId, source: .agentSuggestion,
                                           label: request.agentName, now: now, in: &state)
            }
            return ApprovalAnswered(choice: params.choice, memoryId: memoryID)
        case .approvalsSettingsGet, .approvalsSettingsSet:
            if let change = params as? ApprovalSettingsChange { state.approvalsEnabled = change.enabled }
            // No tag: the demo never subscribes to a doorbell.
            return ApprovalSettings(enabled: state.approvalsEnabled, tag: nil, doorbell: .unsupported)
        }
    }

    // MARK: Memories

    // MARK: Search answers (v0.6)

    /// The demo's sample questions: the memories each finds (its search matches whole phrases,
    /// so a question would find nothing on its own) and a canned answer quoting them.
    struct SampleQuestion {
        let question: String
        let titles: [String]
        let claims: [(text: String, title: String, quote: String)]
    }

    static let sampleQuestions = [
        SampleQuestion(question: "When does my lease renew?", titles: ["Flat lease renews in March"], claims: [
            ("Your flat's lease renews on 1 March, and notice is due two months before.", "Flat lease renews in March",
             "The flat's lease renews on 1 March; notice is due two months before."),
        ]),
        SampleQuestion(question: "What's my next garden milestone?", titles: ["Garden planner: next milestone", "Garden planner app"], claims: [
            ("Your next milestone for the garden planner is the sowing calendar view.", "Garden planner: next milestone",
             "Next milestone is the sowing calendar view."),
            ("You plan a beta for friends by the end of the month.", "Garden planner: next milestone", "Beta to friends by the end of the month."),
        ]),
        SampleQuestion(question: "How often do I run?", titles: ["Running three times a week"], claims: [
            ("You run three times a week, on Tuesday, Thursday and Saturday mornings.", "Running three times a week",
             "runs on Tuesday, Thursday and Saturday mornings"),
        ]),
    ]

    /// The sample question a search is, ignoring case, punctuation and spacing.
    static func sample(_ query: String) -> SampleQuestion? {
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        return sampleQuestions.first { key($0.question) == key(query) }
    }

    /// A canned answer for a sample question, citing the demo's memories; any other search gets
    /// the hint (`AnswerWording`).
    private static func answer(_ params: MemoryAnswerParams, in state: State) throws(CompanionError) -> MemoryAnswerResult {
        guard let sample = sample(params.query) else { throw CompanionError(.modelUnavailable, reason: AnswerWording.demoHintReason) }
        let byTitle = Dictionary(state.memories.values.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        let claims = sample.claims.compactMap { claim -> MemoryAnswerResult.Claim? in
            guard let memory = byTitle[claim.title], params.ids.contains(memory.id), memory.status == .active else { return nil }
            return MemoryAnswerResult.Claim(text: claim.text, citations: [.init(id: memory.id, quote: claim.quote)])
        }
        let read = params.ids.filter { state.memories[$0]?.status == .active }.count
        return MemoryAnswerResult(outcome: claims.isEmpty ? .noAnswer : .answered, claims: claims, read: read, withheld: 0, dropped: 0,
                                  engine: "Demo", locality: .onDevice, durationMs: 1_200)
    }

    private static func search(_ params: MemorySearchParams, in state: State) -> MemorySearchResult {
        let filters = params.filters
        let status = filters?.status ?? .active
        let query = params.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == .active, let sample = sample(query) {
            let found = sample.titles.compactMap { title in state.memories.values.first { $0.title == title && $0.status == .active } }
            return MemorySearchResult(results: found.map {
                MemorySummary(id: $0.id, title: $0.title, snippet: $0.body, kind: $0.kind, categories: $0.categoryKeys,
                              sensitivity: $0.sensitivity, updatedAt: $0.updatedAt, expiresAt: $0.expiresAt)
            })
        }
        let hits = state.memories.values
            .filter { $0.status == status }
            .filter { memory in filters?.categories.map { !Set($0).isDisjoint(with: memory.categoryKeys) } ?? true }
            .filter { memory in filters?.kinds.map { $0.contains(memory.kind) } ?? true }
            .filter { memory in filters?.sensitivities.map { $0.contains(memory.sensitivity) } ?? true }
            .filter { query.isEmpty || $0.title.localizedStandardContains(query) || $0.body.localizedStandardContains(query) }
            // Title matches first, as the Mac's ranking puts them, then the newest.
            .sorted { lhs, rhs in
                let left = !query.isEmpty && lhs.title.localizedStandardContains(query)
                let right = !query.isEmpty && rhs.title.localizedStandardContains(query)
                if left != right { return left }
                return lhs.updatedAt > rhs.updatedAt
            }
        let offset = params.cursor.flatMap(Int.init) ?? 0
        let page = Array(hits.dropFirst(offset).prefix(params.limit ?? 20))
        let results = page.map {
            MemorySummary(id: $0.id, title: $0.title, snippet: $0.body, kind: $0.kind, categories: $0.categoryKeys,
                          sensitivity: $0.sensitivity, updatedAt: $0.updatedAt, expiresAt: $0.expiresAt)
        }
        return MemorySearchResult(results: results, nextCursor: offset + page.count < hits.count ? String(offset + page.count) : nil)
    }

    private static func current(_ id: UUID, version: Int, in state: State) throws(CompanionError) -> Memory {
        guard let memory = state.memories[id] else { throw CompanionError(.notFound) }
        guard memory.version == version else { throw CompanionError(.conflict) }
        return memory
    }

    private static func apply(_ changes: MemoryChanges, to memory: inout Memory) {
        memory.title = changes.title ?? memory.title
        memory.body = changes.body ?? memory.body
        memory.kind = changes.kind ?? memory.kind
        memory.categoryKeys = changes.categories ?? memory.categoryKeys
        memory.sensitivity = changes.sensitivity ?? memory.sensitivity
        if let expiry = changes.expiresAt { memory.expiresAt = expiry }
    }

    private static func save(_ memory: Memory, event: ProvenanceEvent, now: Date, in state: inout State) -> MemoryVersion {
        var memory = memory
        memory.version += 1
        memory.updatedAt = now
        state.memories[memory.id] = memory
        state.provenance[memory.id, default: []].append(ProvenanceLabel(at: now, event: event.rawValue, label: "This iPhone (Demo)"))
        return MemoryVersion(version: memory.version)
    }

    private static func add(_ memory: Memory, event: ProvenanceEvent, label: String, in state: inout State) {
        state.memories[memory.id] = memory
        state.provenance[memory.id] = [ProvenanceLabel(at: memory.createdAt, event: event.rawValue, label: label)]
    }

    /// An Inbox Save or a Save request's answer, as its own action: a new memory, a correction or
    /// an archive of its target, or nothing for a duplicate.
    private static func applySuggestion(_ fields: MemoryChanges, action: SuggestionAction, target: UUID?, source: MemorySource,
                                        label: String, now: Date, in state: inout State) -> UUID {
        if action != .create, let target, var memory = state.memories[target] {
            switch action {
            case .duplicate: return target
            case .archive: memory.status = .archived
            default: apply(fields, to: &memory)
            }
            _ = save(memory, event: .appliedFromSuggestion, now: now, in: &state)
            return target
        }
        let memory = Memory(title: fields.title ?? "", body: fields.body ?? "", kind: fields.kind ?? .fact,
                            categoryKeys: fields.categories ?? [], sensitivity: fields.sensitivity ?? .low,
                            expiresAt: fields.expiresAt ?? nil, source: source, createdAt: now, updatedAt: now)
        add(memory, event: .appliedFromSuggestion, label: label, in: &state)
        return memory.id
    }

    /// `inbox.get`: the card with its memories as they are now. The revision is their versions.
    private static func card(_ item: InboxItem, in state: State) -> InboxDetail {
        let card = state.cards[item.id] ?? Card()
        let memories = card.refs.compactMap { ref in state.memories[ref.id].map { InboxMemory(role: ref.role, memory: $0) } }
        let revision = card.refs.map { "\($0.id):\($0.version):\(state.memories[$0.id]?.version ?? -1)" }.joined(separator: ",")
        return InboxDetail(item: item, memories: memories, pieces: card.pieces, stale: stale(card, in: state), tidyUp: card.tidyUp,
                           revision: revision)
    }

    /// A memory it refers to changed, or isn't active, since the card was made (or reviewed again).
    private static func stale(_ card: Card, in state: State) -> Bool {
        card.refs.contains { ref in state.memories[ref.id].map { $0.status != .active || $0.version != ref.version } ?? true }
    }

    /// `inbox.apply` with the card's choice, as the Mac's per-action apply does it.
    private static func applyCard(_ item: InboxItem, _ params: InboxApplyParams, now: Date, in state: inout State) throws(CompanionError) -> UUID {
        let card = state.cards[item.id] ?? Card()
        let fields = item.memoryChanges.merged(params.edits)
        let source: MemorySource = switch item.origin {
        case .agent: .agentSuggestion
        case .consolidation: .tidyUp
        default: .captureIPhone
        }
        func archive(_ id: UUID) {
            guard var memory = state.memories[id] else { return }
            memory.status = .archived
            _ = save(memory, event: .appliedFromSuggestion, now: now, in: &state)
        }
        func create(_ fields: MemoryChanges) -> UUID {
            applySuggestion(fields, action: .create, target: nil, source: source, label: item.sourceLabel, now: now, in: &state)
        }
        switch (item.action, params.mode) {
        case (.update, .keepBoth):
            guard item.origin != .consolidation else { throw CompanionError(.unsupportedAction) }
            return create(fields)
        case (.create, nil), (.update, nil), (.update, .replace), (.archive, nil), (.duplicate, nil):
            return applySuggestion(fields, action: item.action, target: item.targetMemoryId, source: source,
                                   label: item.sourceLabel, now: now, in: &state)
        case (.merge, nil):
            let id = create(fields)
            for ref in card.refs where ref.role == .source { archive(ref.id) }
            return id
        case (.split, nil):
            let ids = card.pieces.filter { $0.action == .create }.map { create($0.memoryChanges) }
            guard let first = ids.first else { throw CompanionError(.conflict) }
            if let target = item.targetMemoryId { archive(target) }
            return first
        case (.conflict, .keep):
            guard let kept = params.keepMemoryId, card.refs.contains(where: { $0.id == kept }), var memory = state.memories[kept] else {
                throw CompanionError(.unsupportedAction)
            }
            if let edits = params.edits, !edits.isEmpty {
                apply(edits, to: &memory)
                _ = save(memory, event: .appliedFromSuggestion, now: now, in: &state)
            }
            for ref in card.refs where ref.id != kept { archive(ref.id) }
            return kept
        case (.conflict, .bothTrue):
            return card.refs.first?.id ?? item.id
        default:
            throw CompanionError(.unsupportedAction)
        }
    }

    /// A capture's first line, as its Inbox title.
    static func title(for text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }

    // MARK: Approvals

    private static func detail(_ index: Int, in state: State, now: Date) -> ApprovalDetail {
        let request = state.approvals[index]
        var detail = ApprovalDetail(id: state.approvalIDs[index], kind: request.kind, revision: revision, agentName: request.agentName,
                                    agentKind: request.agentKind, task: request.task, createdAt: now.addingTimeInterval(-60),
                                    expiresAt: now.addingTimeInterval(requestLifetime))
        switch request.kind {
        case .share:
            let rows = (request.rows ?? []).compactMap { row -> ApprovalRow? in
                guard let memory = state.memories.values.first(where: { $0.title == row.memory && $0.status == .active }) else { return nil }
                return ApprovalRow(id: memory.id, title: memory.title, body: memory.body, version: memory.version, kind: memory.kind,
                                   categories: memory.categoryKeys, sensitivity: memory.sensitivity, weak: row.weak)
            }
            detail.share = SharePanel(destination: ApprovalDestination(remote: false), keywords: request.keywords ?? [],
                                      purpose: request.purpose, retention: request.retention ?? .session, processors: [],
                                      // No note of the user's own: the Mac shows one only when they set it.
                                      declaredRetention: nil, rows: rows,
                                      withheld: Dictionary(uniqueKeysWithValues: (request.withheld ?? [:]).compactMap { key, count in
                                          ReasonCode(rawValue: key).map { ($0, count) }
                                      }))
        case .save:
            detail.save = request.save.map {
                SavePanel(action: $0.action, title: $0.title, body: $0.body, kind: $0.kind, categories: $0.categories,
                          sensitivity: $0.sensitivity, evidence: $0.evidence, purpose: $0.purpose)
            }
        case .access:
            detail.access = request.access.map {
                AccessPanel(operation: $0.operation, categoryKey: $0.categoryKey, categoryName: $0.categoryName, allowsOnce: $0.allowsOnce,
                            asksBeforeSharing: $0.asksBeforeSharing)
            }
        }
        return detail
    }

    // MARK: Overview

    /// `overview.get` from the sample days, the last of which is today: in, out and refused by
    /// day, grouped into the range's buckets as the Mac groups them. The vault's totals and the
    /// shared mix are the sample's own, scaled to what the range shared.
    static func overview(_ range: OverviewRange, in state: State, now: Date) -> VaultOverview {
        let buckets = OverviewCalendar(calendar: state.calendar)
        let bounds = buckets.boundaries(range, now: now)
        let dayStarts = buckets.dayBoundaries(VaultOverview.Rhythm.days, now: now)
        let sample = state.overview ?? DemoContent.Overview()
        let days = Array(sample.days.suffix(VaultOverview.Rhythm.days))
        let first = VaultOverview.Rhythm.days - days.count
        let ids = state.overviewAgentIDs.map { $0.uuidString.lowercased() }

        var series = bounds.dropLast().map { VaultOverview.Bucket(date: $0) }
        var shared: [String: Int] = [:], requests: [String: Int] = [:], lastRequest: [String: Date] = [:]
        var refused = 0
        for (offset, day) in days.enumerated() {
            let start = dayStarts[first + offset]
            for (agent, n) in zip(ids, day.out) where n > 0 {
                lastRequest[agent] = min(start.addingTimeInterval(14 * 3_600), now.addingTimeInterval(-10 * 60))
            }
            guard let b = series.indices.last(where: { series[$0].date <= start }), start < bounds.last! else { continue }
            series[b].inbound.add(day.inbound)
            for (agent, n) in zip(ids, day.out) where n > 0 {
                series[b].out[agent, default: 0] += n
                shared[agent, default: 0] += n
                // About three memories a request.
                requests[agent, default: 0] += (n + 2) / 3
            }
            series[b].refused += day.refused
            refused += day.refused
        }

        let week = days.suffix(7)
        let sharedInRange = series.map(\.shared).reduce(0, +)
        let agents = zip(ids, sample.agents).map { id, agent in
            VaultOverview.AgentCount(id: id, name: agent.name, kind: agent.kind, shared: shared[id] ?? 0, requests: requests[id] ?? 0,
                                     lastRequestAt: lastRequest[id])
        }.sorted { ($0.shared, $1.name) > ($1.shared, $0.name) }
        var tidyUp = state.calendar.date(bySettingHour: 3, minute: 4, second: 0, of: now) ?? now
        if tidyUp > now { tidyUp = state.calendar.date(byAdding: .day, value: -1, to: tidyUp) ?? tidyUp }
        return VaultOverview(
            range: range, generatedAt: now, timeZone: state.calendar.timeZone.identifier, total: sample.total,
            thisWeek: VaultOverview.Week(saved: week.map(\.inbound.total).reduce(0, +), shared: week.map { $0.out.reduce(0, +) }.reduce(0, +),
                                         agents: Set(week.flatMap { zip(ids, $0.out).filter { $0.1 > 0 }.map(\.0) }).count,
                                         refused: week.map(\.refused).reduce(0, +)),
            days: series,
            rhythm: VaultOverview.Rhythm(start: dayStarts[0], counts: Array(repeating: 0, count: first) + days.map(\.inbound.total)),
            bySensitivity: sample.bySensitivity, byCategory: sample.byCategory, byKind: sample.byKind,
            sharedBySensitivity: scaled(sample.sharedSensitivity, to: sharedInRange),
            sharedByCategory: scaled(sample.sharedCategory, to: sharedInRange),
            refusedByReason: refused > 0 ? [ReasonCode.deniedByUser.rawValue: refused] : [:],
            withheld: refused > 0 ? [ReasonCode.aboveSensitivityCeiling.rawValue: refused] : [:],
            agents: agents, inboxPending: state.inbox.count, oldestPendingAt: state.inbox.map(\.createdAt).min(), lastTidyUpAt: tidyUp)
    }

    /// `weights` as whole counts that add up to `total`: each its share rounded down, and what's
    /// left to the largest remainders.
    static func scaled(_ weights: [String: Int], to total: Int) -> [String: Int] {
        let sum = weights.values.reduce(0, +)
        guard sum > 0, total > 0 else { return [:] }
        let keys = weights.keys.sorted()
        var counts = Dictionary(uniqueKeysWithValues: keys.map { ($0, weights[$0]! * total / sum) })
        let left = total - counts.values.reduce(0, +)
        for key in keys.sorted(by: { weights[$0]! * total % sum > weights[$1]! * total % sum }).prefix(left) { counts[key, default: 0] += 1 }
        return counts.filter { $0.value > 0 }
    }

    // MARK: Loading

    private static func state(from content: DemoContent, now: Date) -> State {
        let day: TimeInterval = 86_400
        var state = State(macName: content.macName, categories: content.categories.map {
            CompanionCategory(MemoryCategory(key: $0.key, name: $0.name, description: $0.description, builtin: true,
                                             defaultSensitivity: $0.defaultSensitivity))
        }, memories: [:], provenance: [:], shared: [:], inbox: [], approvals: content.approvals, approvalIDs: content.approvals.map { _ in UUID() },
           overview: content.overview, overviewAgentIDs: (content.overview?.agents ?? []).map { _ in UUID() })
        state.calledName = content.calledName
        for sample in content.memories {
            let at = now.addingTimeInterval(-sample.daysAgo * day)
            let memory = Memory(title: sample.title, body: sample.body, kind: sample.kind, categoryKeys: sample.categories,
                                sensitivity: sample.sensitivity, status: sample.status ?? .active,
                                expiresAt: sample.expiresInDays.map { now.addingTimeInterval($0 * day) }, source: .manual,
                                createdAt: at, updatedAt: at, deletedAt: sample.status == .deleted ? at : nil)
            add(memory, event: .created, label: "You", in: &state)
            if let count = sample.sharedCount, count > 0 {
                state.shared[memory.id] = (count, now.addingTimeInterval(-sample.daysAgo * day / 2))
            }
        }
        func memory(_ title: String) -> UUID? { state.memories.values.first { $0.title == title }?.id }
        func item(_ sample: DemoContent.Suggestion) -> InboxItem {
            InboxItem(id: UUID(), origin: sample.origin, action: sample.action, sourceLabel: sample.sourceLabel,
                      targetMemoryId: sample.updates.flatMap(memory),
                      title: sample.title, body: sample.body, kind: sample.kind, categories: sample.categories,
                      sensitivity: sample.sensitivity, evidence: sample.evidence, purpose: sample.purpose,
                      createdAt: now.addingTimeInterval(-sample.hoursAgo * 3_600))
        }
        for sample in content.inbox {
            let inboxItem = item(sample)
            state.inbox.append(inboxItem)
            var card = Card()
            if let target = inboxItem.targetMemoryId { card.refs.append((target, .target, 1)) }
            for ref in sample.targets ?? [] {
                if let id = memory(ref.memory), id != inboxItem.targetMemoryId { card.refs.append((id, ref.role, 1)) }
            }
            if sample.origin == .consolidation {
                card.tidyUp = InboxTidyUp(reason: sample.reason, archiveReason: sample.archiveReason,
                                          kept: (sample.kept ?? []).compactMap { k in memory(k.memory).map { .init(memoryId: $0, text: k.text) } })
            }
            card.pieces = (sample.pieces ?? []).map(item)
            state.cards[inboxItem.id] = card
        }
        return state
    }
}

/// `demo-vault.json`: the demo vault's contents, with times relative to when the demo opens.
public struct DemoContent: Codable, Sendable {
    public struct Category: Codable, Sendable {
        var key: String
        var name: String
        var description: String
        var defaultSensitivity: Sensitivity
    }

    public struct Sample: Codable, Sendable {
        var title: String
        var body: String
        var kind: MemoryKind
        var categories: [String]
        var sensitivity: Sensitivity
        var status: MemoryStatus?
        var daysAgo: Double
        var expiresInDays: Double?
        var sharedCount: Int?
    }

    public struct Suggestion: Codable, Sendable {
        var origin: SuggestionOrigin
        var action: SuggestionAction
        var sourceLabel: String
        /// A correction's target, by title.
        var updates: String?
        var title: String
        var body: String
        var kind: MemoryKind
        var categories: [String]
        var sensitivity: Sensitivity
        var evidence: String?
        var purpose: String?
        var hoursAgo: Double
        /// The other memories it refers to, by title (companion protocol §4.2).
        var targets: [Target]?
        /// The tidy-up's reasons.
        var reason: String?
        var archiveReason: InboxArchiveReason?
        var kept: [Kept]?
        /// A split's pieces.
        var pieces: [Suggestion]?

        struct Target: Codable, Sendable {
            var memory: String
            var role: InboxMemoryRole
        }

        struct Kept: Codable, Sendable {
            var memory: String
            var text: String
        }
    }

    public struct Approval: Codable, Sendable {
        public struct Row: Codable, Sendable {
            /// The memory, by title.
            var memory: String
            var weak: Bool
        }

        public struct Save: Codable, Sendable {
            var action: SuggestionAction
            var targetMemoryId: UUID?
            var title: String
            var body: String
            var kind: MemoryKind
            var categories: [String]
            var sensitivity: Sensitivity
            var evidence: String?
            var purpose: String?

            var memoryChanges: MemoryChanges {
                MemoryChanges(title: title, body: body, kind: kind, categories: categories, sensitivity: sensitivity)
            }
        }

        public struct Access: Codable, Sendable {
            var operation: AccessOperation
            var categoryKey: String?
            var categoryName: String?
            var allowsOnce: Bool
            var asksBeforeSharing: Bool
        }

        var kind: ApprovalKind
        var agentName: String
        var agentKind: AgentKind?
        var task: String?
        var keywords: [String]?
        var purpose: String?
        var retention: Retention?
        var rows: [Row]?
        var withheld: [String: Int]?
        var save: Save?
        var access: Access?
    }

    /// 12 weeks of sample counts for `overview.get`, and the vault's sample totals (the 20
    /// memories above would make an empty chart). No real names.
    public struct Overview: Codable, Sendable {
        public struct Agent: Codable, Sendable {
            var name: String
            var kind: AgentKind
        }

        public struct Day: Codable, Sendable {
            /// New memories: Mac, iPhone, agent, import, tidy-up.
            var `in`: [Int]
            /// Memories shared with each agent, in `agents`' order.
            var out: [Int]
            var refused: Int

            var inbound: VaultOverview.Sources {
                let n = `in` + Array(repeating: 0, count: max(0, 5 - `in`.count))
                return VaultOverview.Sources(mac: n[0], iphone: n[1], agent: n[2], import: n[3], tidy: n[4])
            }
        }

        var total = 0
        var bySensitivity: [String: Int] = [:]
        var byCategory: [String: Int] = [:]
        var byKind: [String: Int] = [:]
        /// The mix of what was shared, as weights.
        var sharedSensitivity: [String: Int] = [:]
        var sharedCategory: [String: Int] = [:]
        var agents: [Agent] = []
        /// Oldest first; the last is the day the demo opens.
        var days: [Day] = []
    }

    var macName: String
    var categories: [Category]
    var memories: [Sample]
    var inbox: [Suggestion]
    var approvals: [Approval]
    var overview: Overview?
    /// The demo person's name; absent in older files.
    var calledName: String?
}

extension InboxItem {
    /// The suggestion's fields, as an edit to apply.
    var memoryChanges: MemoryChanges {
        MemoryChanges(title: title, body: body, kind: kind, categories: categories, sensitivity: sensitivity, expiresAt: .some(expiresAt))
    }
}

extension MemoryChanges {
    /// These fields, with `edits` (Edit & Save) on top.
    func merged(_ edits: MemoryChanges?) -> MemoryChanges {
        guard let edits else { return self }
        return MemoryChanges(title: edits.title ?? title, body: edits.body ?? body, kind: edits.kind ?? kind,
                             categories: edits.categories ?? categories, sensitivity: edits.sensitivity ?? sensitivity,
                             expiresAt: edits.expiresAt ?? expiresAt)
    }
}
