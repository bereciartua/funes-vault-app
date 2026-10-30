import Foundation
import FunesCore
import FunesProtocol
import os
import Synchronization

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "companion")

/// The vault services the companion methods use.
public struct CompanionServices: Sendable {
    public let store: VaultStore
    public let devices: DeviceService
    public let captures: CaptureService
    public let suggestions: SuggestionService
    public let search: SearchService
    public let agents: AgentService
    public let activity: any ActivityRecorder
    /// Search answers with the Mac's settings (v0.6); without it `memories.answer` is `answers_off`.
    public var answers: (any SearchAnswering)?

    public init(store: VaultStore, devices: DeviceService, captures: CaptureService, suggestions: SuggestionService,
                search: SearchService, agents: AgentService, activity: any ActivityRecorder, answers: (any SearchAnswering)? = nil) {
        self.store = store
        self.devices = devices
        self.captures = captures
        self.suggestions = suggestions
        self.search = search
        self.agents = agents
        self.activity = activity
        self.answers = answers
    }
}

/// The companion methods (§4). Each acts as the **owner** (access policy §6): no agent access,
/// panels or ceilings, but the same validation and secret scanner, and Activity rows under
/// `device:<id>`. FunesCore logs the writes; this logs the reads. `status.get`, the phone's
/// reachability probe, isn't logged.
public final class CompanionHandlers: Sendable {
    public static let callTimeout: Duration = .seconds(10)
    /// `memories.answer`'s own deadline (§7): the model's 45 s and the preparation.
    public static let answerTimeout: Duration = .seconds(50)
    static let snippetLength = 160

    /// One `memories.answer` in flight per device: a new one cancels the previous (§7).
    private let answering = Mutex<[UUID: (token: UUID, task: Task<(SearchAnswerEngine, SearchAnswer), any Error>)]>([:])

    let services: CompanionServices
    let macName: @Sendable () -> String
    let appVersion: String
    /// The `approvals.*` methods (task 5.6); without it they're `unavailable`.
    let approvals: CompanionApprovals?
    /// The overview's days begin in the Mac's time zone (ADR-0025).
    let calendar: Calendar
    /// The deadlines of §7 (shorter in tests).
    let callLimit: Duration
    let answerLimit: Duration

    public init(services: CompanionServices, macName: @escaping @Sendable () -> String, appVersion: String,
                approvals: CompanionApprovals? = nil, calendar: Calendar = .autoupdatingCurrent,
                callTimeout: Duration = CompanionHandlers.callTimeout, answerTimeout: Duration = CompanionHandlers.answerTimeout) {
        self.services = services
        self.macName = macName
        self.appVersion = appVersion
        self.approvals = approvals
        self.calendar = calendar
        callLimit = callTimeout
        answerLimit = answerTimeout
    }

    /// The reply JSON for a request's plaintext. Never throws: every failure is an error reply.
    func handle(_ plaintext: Data, deviceID: UUID, limits: DeviceLimits, now: Date) async -> Data {
        let head: CompanionRequestHead
        do { head = try CompanionRequestHead(plaintext: plaintext) } catch { return Self.errorReply(id: "", error) }
        guard let method = head.method else {
            return Self.errorReply(id: head.id, CompanionError(.unknownMethod))
        }
        let device = deviceID
        if method == .memoriesAnswer {
            return await withTimeout(id: head.id, limit: answerLimit, error: CompanionError(.modelTimeout, message: "Deadline")) { [self] in
                await run(MemoriesAnswer.self, head) { try await answer($0, device: device, now: now) }
            }
        }
        return await withTimeout(id: head.id, limit: callLimit) { [self] in
            switch method {
            case .statusGet: return await run(StatusGet.self, head) { _ in try await status(now: now) }
            case .capturesSubmit:
                return await run(CapturesSubmit.self, head) { try await submit($0, device: device, limits: limits, now: now) }
            case .overviewGet: return await run(OverviewGet.self, head) { try overview($0, device: device, now: now) }
            case .categoriesList: return await run(CategoriesList.self, head) { _ in try await categories(device: device, now: now) }
            case .memoriesSearch: return await run(MemoriesSearch.self, head) { try await search($0, device: device, now: now) }
            case .memoriesAnswer: return Self.errorReply(id: head.id, CompanionError(.internalError))
            case .memoriesGet: return await run(MemoriesGet.self, head) { try await memory($0.id, device: device, now: now) }
            case .memoriesCreate: return await run(MemoriesCreate.self, head) { try await create($0, device: device, now: now) }
            case .memoriesUpdate: return await run(MemoriesUpdate.self, head) { try await update($0, device: device, now: now) }
            case .memoriesArchive:
                return await run(MemoriesArchive.self, head) { try await setStatus($0, .archived, device: device, now: now) }
            case .memoriesRestore:
                return await run(MemoriesRestore.self, head) { try await setStatus($0, .active, device: device, now: now) }
            case .memoriesDelete:
                return await run(MemoriesDelete.self, head) { try await setStatus($0, .deleted, device: device, now: now) }
            case .inboxList: return await run(InboxList.self, head) { try await inbox($0, device: device, now: now) }
            case .inboxApply: return await run(InboxApply.self, head) { try await apply($0, device: device, now: now) }
            case .inboxReject: return await run(InboxReject.self, head) { try await reject($0, device: device, now: now) }
            case .inboxRetry: return await run(InboxRetry.self, head) { try await retry($0, device: device, now: now) }
            case .inboxKeep: return await run(InboxKeep.self, head) { try await keep($0, device: device, now: now) }
            case .deviceUnpair: return await run(DeviceUnpair.self, head) { _ in try await unpair(device: device, now: now) }
            case .approvalsList:
                return await run(ApprovalsList.self, head) { _ in try await desk().list(device: device, now: now) }
            case .approvalsGet:
                return await run(ApprovalsGet.self, head) { try await desk().detail($0, device: device, now: now) }
            case .approvalsAnswer:
                return await run(ApprovalsAnswer.self, head) { try await desk().answer($0, device: device, now: now) }
            case .approvalsSettingsGet:
                return await run(ApprovalsSettingsGet.self, head) { _ in try await desk().settings(device: device) }
            case .approvalsSettingsSet:
                return await run(ApprovalsSettingsSet.self, head) { try await desk().setSettings($0, device: device, now: now) }
            }
        }
    }

    // MARK: Methods

    func status(now: Date) async throws -> CompanionStatus {
        let pending = try await services.suggestions.pending().count
        let calledName = try services.store.profile().normalized().calledName
        let engine = await services.answers?.engine()
        return CompanionStatus(macName: macName(), appVersion: appVersion, serverTime: now, inboxPending: pending, vaultActive: true,
                               calledName: calledName,
                               searchAnswers: engine.map { SearchAnswersStatus(engine: $0.name, locality: AnswerLocality($0.locality), trigger: $0.trigger) })
    }

    /// `memories.answer` (v0.6): the Mac re-reads the ids as the owner and answers from them
    /// (memory processing §10.3–10.4). A new call from the same device cancels this one, which
    /// ends its model call; the result never carries offsets or more than the claims.
    func answer(_ params: MemoryAnswerParams, device: UUID, now: Date) async throws -> MemoryAnswerResult {
        try params.validate()
        guard let answers = services.answers else { throw CompanionError(.answersOff) }
        // Registered before anything waits, so the same device's next Ask always cancels this one,
        // and this one can't cancel a newer one.
        let token = UUID()
        let task = Task { () throws -> (SearchAnswerEngine, SearchAnswer) in
            guard let engine = await answers.engine() else { throw CompanionError(.answersOff) }
            // Asked on its own by a phone whose status is older than the Mac's setting. `answer`
            // checks again as it chooses the model, in case the setting changes in between.
            let automatic = params.automatic == true
            if automatic, !engine.trigger.fires(for: params.query) { throw CompanionError(.askRequired) }
            try Task.checkCancellation()
            return (engine, try await answers.answer(params.query, ids: params.ids, actor: .device(device), via: .companion,
                                                     automatic: automatic))
        }
        let previous = answering.withLock { inFlight -> Task<(SearchAnswerEngine, SearchAnswer), any Error>? in
            let old = inFlight[device]?.task
            inFlight[device] = (token, task)
            return old
        }
        previous?.cancel()
        defer { answering.withLock { if $0[device]?.token == token { $0[device] = nil } } }
        do {
            let (engine, answer) = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            return MemoryAnswerResult(
                outcome: answer.outcome == .answered ? .answered : .noAnswer,
                claims: answer.claims.map { claim in
                    MemoryAnswerResult.Claim(text: claim.text, citations: claim.citations.map { .init(id: $0.memoryID, quote: $0.quote) })
                },
                read: answer.read, withheld: answer.withheld, dropped: answer.dropped, engine: engine.name,
                locality: AnswerLocality(answer.locality ?? engine.locality), durationMs: Int(answer.duration / .milliseconds(1)))
        } catch let error as SearchAnswerError {
            throw Self.code(for: error)
        } catch is CancellationError {
            throw CompanionError(.unavailable, message: "Cancelled")
        }
    }

    /// `memories.answer`'s errors (§4): `model_unavailable` carries the reason.
    static func code(for error: SearchAnswerError) -> CompanionError {
        switch error {
        case .capReached: CompanionError(.capReached)
        case .timeout: CompanionError(.modelTimeout)
        case .vault: CompanionError(.internalError)
        case .secretInSearch: CompanionError(.modelUnavailable, reason: "secret_in_search")
        case .invalidOutput: CompanionError(.modelUnavailable, reason: "invalid_output")
        case .provider(.unauthorized): CompanionError(.modelUnavailable, reason: "not_signed_in")
        case .provider(.rateLimited): CompanionError(.modelUnavailable, reason: "plan_limit")
        case .needsUpdate: CompanionError(.modelUnavailable, reason: "needs_update")
        case .toolBlocked: CompanionError(.modelUnavailable, reason: "tool_blocked")
        case .askRequired: CompanionError(.askRequired)
        case .tooLongForOnDevice, .provider: CompanionError(.modelUnavailable, reason: "provider_error")
        }
    }

    /// Each capture on its own, so one bad capture doesn't refuse the rest. A duplicate
    /// `captureId` is accepted without storing anything (§6).
    func submit(_ params: CapturesSubmitParams, device: UUID, limits: DeviceLimits, now: Date) async throws -> CapturesSubmitResult {
        try params.validate()
        let admitted = await limits.admitCaptures(deviceID: device, count: params.captures.count, now: now)
        var accepted: [UUID] = []
        var rejected: [CaptureRejection] = []
        for (index, capture) in params.captures.enumerated() {
            guard index < admitted else {
                rejected.append(CaptureRejection(captureId: capture.captureId, reason: .rateLimited))
                continue
            }
            let text = capture.note.map { capture.text + "\n\n" + $0 } ?? capture.text
            do {
                _ = try await services.captures.capture(text, origin: .captureIPhone, captureID: capture.captureId,
                                                        deviceID: device, now: now)
                accepted.append(capture.captureId)
            } catch let error as VaultError {
                if error == .unauthenticated { throw error }
                rejected.append(CaptureRejection(captureId: capture.captureId, reason: Self.code(for: error).code))
            }
        }
        return CapturesSubmitResult(accepted: accepted, rejected: rejected)
    }

    /// Counts only (ADR-0025), so the Activity row carries none either.
    func overview(_ params: OverviewParams, device: UUID, now: Date) throws -> VaultOverview {
        let overview = try services.store.overview(params.range, now: now, calendar: calendar)
        logRead("overview_viewed", device: device, now: now)
        return overview
    }

    func categories(device: UUID, now: Date) async throws -> [CompanionCategory] {
        let all = try services.store.categories()
        logRead("categories_listed", device: device, now: now)
        return all.map(CompanionCategory.init)
    }

    func search(_ params: MemorySearchParams, device: UUID, now: Date) async throws -> MemorySearchResult {
        try params.validate()
        let filter = MemoryFilter(status: Self.status(params.filters?.status),
                                  categoryKeys: Set(params.filters?.categories ?? []), kinds: Set(params.filters?.kinds ?? []),
                                  sensitivities: Set(params.filters?.sensitivities ?? []))
        let hits = try await services.search.vaultSearch(params.query, filter: filter, now: now)
        let offset = params.cursor.flatMap(Self.offset(from:)) ?? 0
        let limit = params.limit ?? 20
        let page = Array(hits.dropFirst(offset).prefix(limit))
        let memories = try services.store.memories(ids: page.map(\.memoryID))
        let byID = Dictionary(uniqueKeysWithValues: memories.map { ($0.id, $0) })
        // The passage that matches the search and its matches (FR-V-17), for the page returned only.
        let matches = try await services.search.bodyMatches(params.query, ids: page.map(\.memoryID))
        let results = page.compactMap { byID[$0.memoryID] }.map { m in
            let snippet = matches[m.id]?.snippet(length: Self.snippetLength) ?? BodyMatches.plainSnippet(m.body, length: Self.snippetLength)
            return MemorySummary(id: m.id, title: m.title, snippet: snippet.text, snippetMatches: snippet.matches.isEmpty ? nil : snippet.matches,
                                 kind: m.kind, categories: m.categoryKeys, sensitivity: m.sensitivity, updatedAt: m.updatedAt,
                                 expiresAt: m.expiresAt)
        }
        let next = offset + page.count < hits.count ? Self.cursor(offset + page.count) : nil
        logRead("memories_searched", device: device, now: now, counts: ["results": results.count])
        return MemorySearchResult(results: results, nextCursor: next)
    }

    func memory(_ id: UUID, device: UUID, now: Date) async throws -> CompanionMemory {
        guard let memory = try services.store.memory(id: id) else { throw VaultError.notFound }
        let provenance = try services.store.provenance(memoryID: id)
        let deviceNames = try await deviceNames()
        let agentNames = try await agentNames()
        let labels = provenance.map { entry in
            ProvenanceLabel(at: entry.at, event: entry.event.rawValue,
                            label: Self.label(entry.actor, devices: deviceNames, agents: agentNames))
        }
        let shared = try await services.devices.sharing(memoryID: id)
        logRead("memory_viewed", device: device, now: now, ids: [id])
        return CompanionMemory(memory: memory, provenance: labels, sharedCount: shared.count, lastSharedAt: shared.last)
    }

    func create(_ params: MemoryCreateParams, device: UUID, now: Date) async throws -> MemoryCreated {
        let memory = try await services.devices.createMemory(deviceID: device, MemoryDraft(
            title: params.title, body: params.body, kind: params.kind, categoryKeys: params.categories,
            sensitivity: params.sensitivity, expiresAt: params.expiresAt), now: now)
        return MemoryCreated(id: memory.id, version: memory.version)
    }

    func update(_ params: MemoryUpdateParams, device: UUID, now: Date) async throws -> MemoryVersion {
        guard !params.changes.isEmpty else { throw CompanionError(.invalidInput, message: "No changes") }
        let memory = try await services.devices.updateMemory(deviceID: device, memoryID: params.id, Self.edit(params.changes),
                                                             expectedVersion: params.version, now: now)
        return MemoryVersion(version: memory.version)
    }

    func setStatus(_ ref: MemoryVersionRef, _ status: MemoryStatus, device: UUID, now: Date) async throws -> MemoryVersion {
        let memory = try await services.devices.setMemoryStatus(deviceID: device, memoryID: ref.id, to: status,
                                                                expectedVersion: ref.version, now: now)
        return MemoryVersion(version: memory.version)
    }

    func inbox(_ params: InboxListParams, device: UUID, now: Date) async throws -> InboxListResult {
        let pending = try await services.suggestions.pending()
        let offset = params.cursor.flatMap(Self.offset(from:)) ?? 0
        let page = Array(pending.dropFirst(offset).prefix(50))
        let deviceNames = try await deviceNames()
        let agentNames = try await agentNames()
        let processing = try await services.suggestions.processing(now: now)
        let items = page.map { s in
            // The tidy-up's cards are answered on the Mac until the iPhone gets its own (ADR-0021):
            // an update there may also archive a copy, and an archive names what it keeps.
            InboxItem(id: s.id, origin: s.origin, action: s.origin == .consolidation ? .unknown : s.action,
                      sourceLabel: Self.sourceLabel(s, devices: deviceNames, agents: agentNames), targetMemoryId: s.targetMemoryID,
                      title: s.title, body: s.body, kind: s.kind ?? .fact, categories: s.categoryKeys,
                      sensitivity: s.sensitivity ?? .low, expiresAt: s.expiresAt, evidence: s.evidence, purpose: s.purpose,
                      createdAt: s.createdAt, targetMemoryVersion: s.targetMemoryVersion, groupId: s.groupID,
                      outsideScope: s.outsideScope, processing: processing[s.id].map { $0.isProcessing ? .processing : .failed })
        }
        let next = offset + page.count < pending.count ? Self.cursor(offset + page.count) : nil
        logRead("inbox_listed", device: device, now: now, counts: ["items": items.count])
        return InboxListResult(items: items, nextCursor: next)
    }

    /// The suggestion's own action (6.1.1): an update replaces its target. Merge, split and
    /// conflict, and the tidy-up's proposals, are answered on the Mac (companion protocol §4).
    /// One still processing is refused (`processing`) by FunesCore.
    func apply(_ params: InboxApplyParams, device: UUID, now: Date) async throws -> InboxApplied {
        guard let suggestion = try await services.suggestions.suggestion(id: params.suggestionId) else { throw VaultError.notFound }
        guard suggestion.action.appliesOnPhone, suggestion.origin != .consolidation else { throw VaultError.unsupportedAction }
        let edits = params.edits.map(Self.suggestionEdit) ?? SuggestionEdit()
        let result = try await services.suggestions.apply(suggestionID: params.suggestionId, edits: edits, now: now,
                                                          actor: .device(device), via: .companion)
        return InboxApplied(memoryId: result.memoryID)
    }

    func reject(_ params: SuggestionID, device: UUID, now: Date) async throws -> EmptyResult {
        try await services.suggestions.reject(suggestionID: params.suggestionId, now: now, actor: .device(device), via: .companion)
        return EmptyResult()
    }

    func retry(_ params: SuggestionID, device: UUID, now: Date) async throws -> EmptyResult {
        try await services.suggestions.retryProcessing(suggestionID: params.suggestionId, now: now, actor: .device(device),
                                                       via: .companion)
        return EmptyResult()
    }

    func keep(_ params: SuggestionID, device: UUID, now: Date) async throws -> EmptyResult {
        try await services.suggestions.keepAsOne(suggestionID: params.suggestionId, now: now, actor: .device(device), via: .companion)
        return EmptyResult()
    }

    func unpair(device: UUID, now: Date) async throws -> EmptyResult {
        try await services.devices.revoke(deviceID: device, now: now, actor: .device(device))
        await approvals?.forget(deviceID: device)
        return EmptyResult()
    }

    private func desk() throws(CompanionError) -> CompanionApprovals {
        guard let approvals else { throw CompanionError(.unavailable, message: "No approvals on this Mac") }
        return approvals
    }

    // MARK: Plumbing

    private func run<Call: CompanionCall>(_ call: Call.Type, _ head: CompanionRequestHead,
                                          _ body: (Call.Params) async throws -> Call.Result) async -> Data {
        do {
            let params = try head.params(Call.self)
            let result = try await body(params)
            return (try? CompanionResponse(id: head.id, result: result).encoded()) ?? Self.errorReply(id: head.id, CompanionError(.internalError))
        } catch let error as CompanionError {
            return Self.errorReply(id: head.id, error)
        } catch let error as VaultError {
            return Self.errorReply(id: head.id, Self.code(for: error))
        } catch {
            logger.error("A companion method failed")
            return Self.errorReply(id: head.id, CompanionError(.internalError))
        }
    }

    /// 10 s per call (§7); a slower one answers `unavailable` and keeps running to its end.
    /// (`memories.answer` has its own deadline, past which its work is cancelled.)
    private func withTimeout(id: String, limit: Duration, error: CompanionError = CompanionError(.unavailable, message: "Timed out"),
                             _ work: @escaping @Sendable () async -> Data) async -> Data {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? Self.errorReply(id: id, error)
        }
    }

    static func errorReply(id: String, _ error: CompanionError) -> Data {
        (try? CompanionResponse<EmptyResult>(id: id, error: error).encoded()) ?? Data()
    }

    static func code(for error: VaultError) -> CompanionError {
        switch error {
        case let .secretLikeContent(findings): CompanionError(.secretLikeContent, findings: findings)
        case .notFound: CompanionError(.notFound)
        case .versionConflict, .invalidState, .snapshotChanged, .revisionChanged: CompanionError(.conflict)
        case .targetChanged: CompanionError(.targetChanged)
        case .unsupportedAction: CompanionError(.unsupportedAction)
        case .processing: CompanionError(.processing)
        case .undoNeedsLater, .undoNotPossible: CompanionError(.conflict)
        case .newerSchema, .unsafeFile: CompanionError(.unavailable)
        case .unauthenticated: CompanionError(.notFound)
        case let .invalidInput(field): CompanionError(.invalidInput, message: field)
        case let .unknownCategory(key): CompanionError(.invalidInput, message: "Unknown category \(key)")
        case .noCategories, .builtinCategory, .categoryExists, .categoryInUse, .onlyAllowedCategory, .nameTaken:
            CompanionError(.invalidInput)
        }
    }

    private func logRead(_ event: String, device: UUID, now: Date, ids: [UUID] = [], counts: [String: Int] = [:]) {
        services.activity.record(ActivityEvent(time: now, phase: .event, actor: .device(device), via: .companion, event: event,
                                               outcome: "ok", ids: ids, counts: counts))
    }

    private func deviceNames() async throws -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: try await services.devices.devices(includingRevoked: true).map { ($0.id, $0.name) })
    }

    private func agentNames() async throws -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: try await services.agents.agents(includingRemoved: true).map { ($0.id, $0.name) })
    }

    static func status(_ status: MemoryStatus?) -> MemoryFilter.StatusFilter {
        switch status {
        case .archived: .archived
        case .deleted: .recentlyDeleted
        case .active, nil: .active
        }
    }

    static func cursor(_ offset: Int) -> String { Base64URL.encode(Data("o:\(offset)".utf8)) }

    static func offset(from cursor: String) -> Int? {
        guard let data = Base64URL.decode(cursor), let text = String(data: data, encoding: .utf8), text.hasPrefix("o:"),
              let n = Int(text.dropFirst(2)), n >= 0 else { return nil }
        return n
    }

    static func edit(_ changes: MemoryChanges) -> MemoryEdit {
        MemoryEdit(title: changes.title, body: changes.body, kind: changes.kind, categoryKeys: changes.categories,
                   sensitivity: changes.sensitivity, expiresAt: changes.expiresAt)
    }

    static func suggestionEdit(_ changes: MemoryChanges) -> SuggestionEdit {
        SuggestionEdit(title: changes.title, body: changes.body, kind: changes.kind, categoryKeys: changes.categories,
                       sensitivity: changes.sensitivity, expiresAt: changes.expiresAt)
    }

    static func label(_ actor: String, devices: [UUID: String], agents: [UUID: String]) -> String {
        let parts = actor.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return actor == "user" ? "You" : actor == "system" ? "Funes" : actor }
        switch parts[0] {
        case "device": return devices[id] ?? "iPhone"
        case "agent": return agents[id] ?? "Agent"
        case "import": return "Import"
        default: return actor
        }
    }

    static func sourceLabel(_ s: Suggestion, devices: [UUID: String], agents: [UUID: String]) -> String {
        switch s.origin {
        case .agent: s.agentID.flatMap { agents[$0] } ?? "Agent"
        case .captureIPhone: s.deviceID.flatMap { devices[$0] } ?? "iPhone"
        case .captureMac: "Mac"
        case .import: "Import"
        case .seedQuestion: "A Few Questions"
        case .consolidation: "Funes"
        }
    }
}

extension AnswerLocality {
    init(_ locality: Locality) {
        switch locality {
        case .onDevice: self = .onDevice
        case .localServer: self = .localServer
        case .appleCloud: self = .appleCloud
        case .cloud: self = .cloud
        }
    }
}
