import CryptoKit
import Foundation
import FunesCore
import FunesProtocol
import os

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "approvals")

/// Approvals from the iPhone (task 5.6, FR-iOS-12, ADR-0019): what waits for the user, the
/// doorbell, and the phone's answers.
///
/// - **Waiting:** the app says when a Share, Save or access panel starts waiting and when the Mac
///   answered, withdrew or let it go. Share requests and suggestions live in FunesCore; an access
///   request lives only in the app's panel, so the app hands over the closure that answers it.
/// - **The doorbell:** each waiting request rings every paired device with approvals on and a
///   tag, one record per device with a fresh random name. The names map to the request here, in
///   memory only, and the records are deleted when it stops waiting (and at launch).
/// - **Answers:** bound to the id and the revision the phone showed, single use, with the same
///   15-minute and invalidation rules as on the Mac. FunesCore's transactions decide between the
///   Mac and a phone for Share and Save; the app's panel queue decides for an access request. The
///   first answer wins; the other side sees `already_answered`, and a phone's win withdraws the
///   Mac's panel. Each answer is logged under `device:<id>`.
public actor CompanionApprovals {
    public enum Key: Hashable, Sendable {
        case share(UUID)
        case save(UUID)
        case access(UUID)

        public var id: UUID {
            switch self {
            case let .share(id), let .save(id), let .access(id): id
            }
        }

        var kind: ApprovalKind {
            switch self {
            case .share: .share
            case .save: .save
            case .access: .access
            }
        }
    }

    /// "<Agent> wants to read <Category>", as the app's panel asks it (access policy §7).
    public struct AccessRequest: Sendable {
        public var agentID: UUID
        public var categoryKey: String?
        public var operation: AccessOperation
        public var task: String?
        public var expiresAt: Date
        public var allowsOnce: Bool

        public init(agentID: UUID, categoryKey: String?, operation: AccessOperation, task: String?, expiresAt: Date,
                    allowsOnce: Bool) {
            self.agentID = agentID
            self.categoryKey = categoryKey
            self.operation = operation
            self.task = task
            self.expiresAt = expiresAt
            self.allowsOnce = allowsOnce
        }
    }

    /// Answers the app's access panel with a phone's choice: true if it was still waiting (the
    /// phone won), false if the Mac answered first.
    public typealias AccessAnswerer = @Sendable (ApprovalChoice) async -> Bool

    /// How a request stopped waiting, kept for 15 minutes so a late phone hears why.
    enum Ending: Equatable {
        case answered
        case expired
    }

    private struct AccessWait {
        var request: AccessRequest
        var createdAt: Date
        var revision: String
        var answer: AccessAnswerer
    }

    private struct RingOwner {
        var key: Key
        var deviceID: UUID
        var at: Date
    }

    public static let window = DisclosureService.window

    let services: CompanionServices
    let disclosures: DisclosureService
    let doorbell: any DoorbellChannel

    private var ringing = false
    /// The records rung for each waiting request.
    private var rings: [Key: [DoorbellRing]] = [:]
    /// Record name → request, kept past the end (15 minutes) so a late notification can say why.
    private var owners: [String: RingOwner] = [:]
    /// When the Mac started showing it; a Save panel waits 15 minutes from here.
    private var started: [Key: Date] = [:]
    private var destinations: [UUID: ApprovalDestination] = [:]
    private var accessWaits: [UUID: AccessWait] = [:]
    private var endings: [Key: (Ending, Date)] = [:]
    /// The app: a phone answered first, so withdraw the Mac's panel. With the device's name.
    private var phoneAnswered: @Sendable (Key, String) -> Void = { _, _ in }

    public init(services: CompanionServices, disclosures: DisclosureService, doorbell: any DoorbellChannel = NoDoorbell()) {
        self.services = services
        self.disclosures = disclosures
        self.doorbell = doorbell
    }

    // MARK: The app's side

    public func onPhoneAnswered(_ handler: @escaping @Sendable (Key, String) -> Void) {
        phoneAnswered = handler
    }

    public func doorbellAvailability() async -> DoorbellAvailability {
        await doorbell.availability()
    }

    /// Rings only while iPhone access is on: a phone that can't reach the Mac has nothing to fetch.
    /// Turning it off takes back every ring.
    public func setRinging(_ on: Bool) async {
        ringing = on
        guard !on else { return }
        let all = rings.values.flatMap { $0 }
        rings = rings.mapValues { _ in [] }
        await remove(all)
    }

    /// At launch: the rings a previous run left (it quit or crashed while a request waited).
    public func launch() async {
        let tags = ((try? await services.devices.devices(includingRevoked: true)) ?? []).compactMap(\.doorbellTag)
        guard !tags.isEmpty else { return }
        do { try await doorbell.removeAll(tags: tags) } catch { logger.error("Couldn't delete old doorbell records") }
    }

    /// A Share or Save panel started waiting (not a pending request reopened on the Mac). Rings
    /// each device once per request. `destination` is the Share panel's Goes to line, which only
    /// the app knows (Remote Access and its tunnel).
    public func waiting(_ key: Key, destination: ApprovalDestination? = nil, now: Date = Date()) async {
        if let destination { destinations[key.id] = destination }
        guard started[key] == nil, endings[key] == nil else { return }
        started[key] = now
        await ring(key, now: now)
    }

    /// An access panel started waiting; `answer` answers it from a phone.
    public func waitingForAccess(id: UUID, _ request: AccessRequest, now: Date = Date(),
                                 answer: @escaping AccessAnswerer) async {
        guard accessWaits[id] == nil, endings[.access(id)] == nil else { return }
        accessWaits[id] = AccessWait(request: request, createdAt: now, revision: Self.randomRevision(), answer: answer)
        started[.access(id)] = now
        await ring(.access(id), now: now)
    }

    /// The Mac answered it (`answered`), or it stopped waiting: withdrawn, expired, invalidated.
    /// A Share panel's 45 seconds running out isn't an end: the request still waits 15 minutes.
    public func ended(_ key: Key, answered: Bool, now: Date = Date()) async {
        await end(key, answered ? .answered : .expired, now: now)
    }

    /// The minute job: ends what stopped waiting without the app seeing it (the 15 minutes, an
    /// answer from an agent's `get_memory_request` path, an invalidation), and forgets old endings.
    public func sweep(now: Date = Date()) async {
        for key in Array(started.keys) {
            if let ending = await stillWaiting(key, now: now) { await end(key, ending, now: now) }
        }
        endings = endings.filter { now < $0.value.1 + Self.window }
        owners = owners.filter { now < $0.value.at + Self.window }
    }

    /// Approvals on or off for a device from Settings ▸ iPhone. Off takes back its rings.
    @discardableResult
    public func setApprovals(deviceID: UUID, enabled: Bool, actor: Actor = .user, now: Date = Date()) async throws -> Device {
        let device = try await services.devices.setApprovals(deviceID: deviceID, enabled: enabled, now: now, actor: actor)
        if !enabled { await forget(deviceID: deviceID) }
        return device
    }

    /// A device was removed or unpaired: its rings go.
    public func forget(deviceID: UUID) async {
        var gone: [DoorbellRing] = []
        for (key, list) in rings {
            let (theirs, others) = list.reduce(into: ([DoorbellRing](), [DoorbellRing]())) { split, ring in
                if owners[ring.recordName]?.deviceID == deviceID { split.0.append(ring) } else { split.1.append(ring) }
            }
            gone += theirs
            rings[key] = others
        }
        await remove(gone)
    }

    // MARK: The phone's side (CompanionHandlers)

    /// `approvals.list`: everything still waiting, soonest deadline first.
    func list(device: UUID, now: Date) async throws -> ApprovalListResult {
        _ = try await services.devices.authenticate(deviceID: device)
        var items: [ApprovalSummary] = []
        for d in try await disclosures.pendingRequests(now: now) where d.status == .needsApproval {
            let agent = try await services.agents.agent(id: d.agentID)
            items.append(ApprovalSummary(id: d.id, kind: .share, agentName: agent?.name ?? "", agentKind: agent?.agentKind,
                                         count: d.candidateSnapshot.count, createdAt: d.createdAt,
                                         expiresAt: d.createdAt + Self.window))
        }
        for (key, since) in started {
            guard case let .save(id) = key, let s = try await services.suggestions.suggestion(id: id), s.status == .pending,
                  now < since + Self.window else { continue }
            let agent = try await agent(s.agentID)
            items.append(ApprovalSummary(id: id, kind: .save, agentName: agent?.name ?? "", agentKind: agent?.agentKind, count: 1,
                                         createdAt: since, expiresAt: since + Self.window))
        }
        for (id, wait) in accessWaits where now < wait.request.expiresAt {
            let agent = try await services.agents.agent(id: wait.request.agentID)
            items.append(ApprovalSummary(id: id, kind: .access, agentName: agent?.name ?? "", agentKind: agent?.agentKind,
                                         count: 0, createdAt: wait.createdAt, expiresAt: wait.request.expiresAt))
        }
        items.sort { ($0.expiresAt, $0.createdAt) < ($1.expiresAt, $1.createdAt) }
        log("approvals_listed", device: device, now: now, counts: ["items": items.count])
        return ApprovalListResult(items: items)
    }

    /// `approvals.get`: the panel, built fresh. A Share request's snapshot is re-checked first, so
    /// the revision is the current one (access policy §3.6).
    func detail(_ ref: ApprovalRef, device: UUID, now: Date) async throws -> ApprovalDetail {
        try ref.validate()
        _ = try await services.devices.authenticate(deviceID: device)
        let key = try await resolve(ref)
        let detail: ApprovalDetail
        switch key {
        case let .share(id): detail = try await shareDetail(id, now: now)
        case let .save(id): detail = try await saveDetail(id, now: now)
        case let .access(id): detail = try await accessDetail(id, now: now)
        }
        log("approval_viewed", device: device, now: now, requestID: key.kind == .share ? key.id : nil,
            outcome: key.kind.rawValue)
        return detail
    }

    /// `approvals.answer`.
    func answer(_ params: ApprovalAnswerParams, device: UUID, now: Date) async throws -> ApprovalAnswered {
        try params.validate()
        let phone = try await services.devices.authenticate(deviceID: device)
        let key = try await resolve(ApprovalRef(id: params.id))
        guard params.choice.kind == key.kind else { throw CompanionError(.invalidInput, message: "Wrong answer for this panel") }
        let actor = Actor.device(device)
        var result = ApprovalAnswered(choice: params.choice)
        switch key {
        case let .share(id):
            guard let d = try await disclosures.disclosure(requestID: id) else { throw CompanionError(.notFound) }
            if let ending = Self.ending(d, now: now) { throw Self.error(for: ending) }
            // Re-checked against the current memories and access first, as building the panel does,
            // so a phone that showed a panel before a change is refused (T22) rather than approving
            // what it no longer shows.
            guard let current = try await disclosures.panel(requestID: id, now: now) else {
                let ending = try await disclosures.disclosure(requestID: id).flatMap { Self.ending($0, now: now) } ?? .expired
                await end(key, ending, now: now)
                throw Self.error(for: ending)
            }
            do {
                if params.choice == .share {
                    try await disclosures.approve(requestID: id, snapshotRevision: params.revision, memoryIDs: params.memoryIds ?? [],
                                                  now: now, actor: actor, via: .companion)
                } else {
                    guard current.snapshotRevision == params.revision else { throw CompanionError(.requestChanged) }
                    try await disclosures.deny(requestID: id, now: now, waitingOnly: true, actor: actor, via: .companion)
                }
            } catch VaultError.snapshotChanged {
                throw CompanionError(.requestChanged)
            } catch VaultError.invalidState {
                // Someone answered first, or the 15 minutes ran out just now.
                let ending = try await disclosures.disclosure(requestID: id).flatMap { Self.ending($0, now: now) } ?? .answered
                throw Self.error(for: ending)
            }
        case let .save(id):
            guard let s = try await services.suggestions.suggestion(id: id) else { throw CompanionError(.notFound) }
            if let ending = saveEnding(s, now: now) { throw Self.error(for: ending) }
            guard Self.revision(of: s) == params.revision else { throw CompanionError(.requestChanged) }
            do {
                if params.choice == .save {
                    let applied = try await services.suggestions.apply(suggestionID: id, now: now, actor: actor, via: .companion)
                    result.memoryId = applied.memoryID
                } else {
                    try await services.suggestions.reject(suggestionID: id, now: now, actor: actor, via: .companion)
                }
            } catch VaultError.invalidState {
                throw CompanionError(.alreadyAnswered)
            }
        case let .access(id):
            guard let wait = accessWaits[id] else { throw Self.error(for: endings[key]?.0 ?? .answered) }
            guard now < wait.request.expiresAt else {
                await end(key, .expired, now: now)
                throw CompanionError(.requestExpired)
            }
            guard wait.revision == params.revision else { throw CompanionError(.requestChanged) }
            guard params.choice != .allowOnce || wait.request.allowsOnce else {
                throw CompanionError(.invalidInput, message: "Allow Once isn't offered")
            }
            // Claimed before the await, so a second phone hears `already_answered`.
            accessWaits[id] = nil
            endings[key] = (.answered, now)
            guard await wait.answer(params.choice) else {
                await end(key, .answered, now: now)
                throw CompanionError(.alreadyAnswered)
            }
            services.activity.record(ActivityEvent(time: now, phase: .event, actor: actor, via: .companion, event: "access_answered",
                                                   outcome: params.choice.rawValue))
        }
        await end(key, .answered, now: now)
        phoneAnswered(key, phone.name)
        return result
    }

    /// `approvals.settings.get`: the switch, and the tag to subscribe to while it's on.
    func settings(device: UUID) async throws -> ApprovalSettings {
        let tag = try await services.devices.doorbellTag(deviceID: device)
        let enabled = try await services.devices.authenticate(deviceID: device).approvalsEnabled
        return ApprovalSettings(enabled: enabled, tag: tag, doorbell: await doorbell.availability())
    }

    /// `approvals.settings.set`, from Settings on the phone.
    func setSettings(_ change: ApprovalSettingsChange, device: UUID, now: Date) async throws -> ApprovalSettings {
        _ = try await services.devices.authenticate(deviceID: device)
        try await setApprovals(deviceID: device, enabled: change.enabled, actor: .device(device), now: now)
        return try await settings(device: device)
    }

    // MARK: Panels

    private func shareDetail(_ id: UUID, now: Date) async throws -> ApprovalDetail {
        guard let panel = try await disclosures.panel(requestID: id, now: now) else {
            let ending = try await disclosures.disclosure(requestID: id).flatMap { Self.ending($0, now: now) } ?? .expired
            await end(.share(id), ending, now: now)
            throw Self.error(for: ending)
        }
        let disclosure = try await disclosures.disclosure(requestID: id)
        let agent = try await services.agents.agent(id: panel.agentID)
        let rows = panel.memories.map { m in
            ApprovalRow(id: m.id, title: m.title, body: m.body, version: m.version, kind: m.kind, categories: m.categoryKeys,
                        sensitivity: m.sensitivity, weak: !panel.strong.contains(m.id))
        }
        let destination = destinations[id] ?? ApprovalDestination(remote: agent?.agentKind.isCloud ?? false)
        let declared = agent.flatMap { $0.declaredRetention == .unknown ? nil : $0.declaredRetention }
        return ApprovalDetail(
            id: id, kind: .share, revision: panel.snapshotRevision, agentName: panel.agentName, agentKind: agent?.agentKind,
            task: panel.task, createdAt: panel.createdAt, expiresAt: panel.expiresAt,
            share: SharePanel(destination: destination, keywords: panel.keywords, purpose: panel.purpose, retention: panel.retention,
                              processors: panel.processors, declaredRetention: declared, rows: rows,
                              withheld: disclosure?.withheld ?? [:]))
    }

    private func saveDetail(_ id: UUID, now: Date) async throws -> ApprovalDetail {
        guard let s = try await services.suggestions.suggestion(id: id) else { throw CompanionError(.notFound) }
        if let ending = saveEnding(s, now: now) {
            await end(.save(id), ending, now: now)
            throw Self.error(for: ending)
        }
        let agent = try await agent(s.agentID)
        let since = started[.save(id)] ?? s.createdAt
        return ApprovalDetail(
            id: id, kind: .save, revision: Self.revision(of: s), agentName: agent?.name ?? "", agentKind: agent?.agentKind,
            createdAt: since, expiresAt: since + Self.window,
            save: SavePanel(action: s.action, targetMemoryId: s.targetMemoryID, title: s.title, body: s.body, kind: s.kind,
                            categories: s.categoryKeys, sensitivity: s.sensitivity, expiresAt: s.expiresAt, evidence: s.evidence,
                            purpose: s.purpose))
    }

    private func accessDetail(_ id: UUID, now: Date) async throws -> ApprovalDetail {
        guard let wait = accessWaits[id] else { throw Self.error(for: endings[.access(id)]?.0 ?? .expired) }
        guard now < wait.request.expiresAt else {
            await end(.access(id), .expired, now: now)
            throw CompanionError(.requestExpired)
        }
        let request = wait.request
        let agent = try await services.agents.agent(id: request.agentID)
        let category = try request.categoryKey.flatMap { key in try services.store.categories().first { $0.key == key }?.name }
        return ApprovalDetail(
            id: id, kind: .access, revision: wait.revision, agentName: agent?.name ?? "", agentKind: agent?.agentKind,
            task: request.task, createdAt: wait.createdAt, expiresAt: request.expiresAt,
            access: AccessPanel(operation: request.operation, categoryKey: request.categoryKey, categoryName: category,
                                allowsOnce: request.allowsOnce, asksBeforeSharing: agent?.access.askBeforeSharing ?? true))
    }

    // MARK: Plumbing

    /// The request a ring or an id names. An id is an access request's, a Share request's or an
    /// agent's suggestion's, in that order.
    private func resolve(_ ref: ApprovalRef) async throws -> Key {
        if let ring = ref.ring {
            guard let owner = owners[ring] else { throw CompanionError(.notFound) }
            return owner.key
        }
        guard let id = ref.id else { throw CompanionError(.invalidInput) }
        if accessWaits[id] != nil || endings[.access(id)] != nil { return .access(id) }
        if try await disclosures.disclosure(requestID: id) != nil { return .share(id) }
        if let s = try await services.suggestions.suggestion(id: id), s.origin == .agent { return .save(id) }
        throw CompanionError(.notFound)
    }

    /// Nil while it can still be answered.
    private func stillWaiting(_ key: Key, now: Date) async -> Ending? {
        switch key {
        case let .share(id):
            guard let d = try? await disclosures.disclosure(requestID: id) else { return .expired }
            return Self.ending(d, now: now)
        case let .save(id):
            guard let s = try? await services.suggestions.suggestion(id: id) else { return .expired }
            return saveEnding(s, now: now)
        case let .access(id):
            guard let wait = accessWaits[id] else { return endings[key]?.0 ?? .expired }
            return now < wait.request.expiresAt ? nil : .expired
        }
    }

    /// Answered (approved, delivered, denied by the user), or expired: the 15 minutes, or
    /// invalidated (nothing left to share, replaced by a new request).
    static func ending(_ d: Disclosure, now: Date) -> Ending? {
        switch d.status {
        case .needsApproval: now < d.createdAt + window ? nil : .expired
        case .denied: d.reason == .deniedByUser ? .answered : .expired
        case .evaluating, .failed: .expired
        case .approved, .delivered, .fulfilled: .answered
        }
    }

    private func saveEnding(_ s: Suggestion, now: Date) -> Ending? {
        switch s.status {
        case .applied, .rejected: return .answered
        case .expired: return .expired
        case .pending: return now < (started[.save(s.id)] ?? s.createdAt) + Self.window ? nil : .expired
        }
    }

    static func error(for ending: Ending) -> CompanionError {
        switch ending {
        case .answered: CompanionError(.alreadyAnswered)
        case .expired: CompanionError(.requestExpired)
        }
    }

    /// A Save panel's revision: what the user would save. An edit in the Mac's Inbox changes it.
    static func revision(of s: Suggestion) -> String {
        struct Canonical: Encodable {
            var title: String, body: String, kind: String?, categories: [String], sensitivity: Int?, expiresAt: Double?
            var target: String?, action: String
        }
        let canonical = Canonical(title: s.title, body: s.body, kind: s.kind?.rawValue, categories: s.categoryKeys,
                                  sensitivity: s.sensitivity?.rawValue, expiresAt: s.expiresAt?.timeIntervalSince1970,
                                  target: s.targetMemoryID?.uuidString.lowercased(), action: s.action.rawValue)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(canonical)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func randomRevision() -> String { DoorbellRing.randomName() }

    private func ring(_ key: Key, now: Date) async {
        guard ringing else { return }
        // Reserved before the first await, so the same request never rings twice.
        rings[key] = []
        let devices = (try? await services.devices.devices()) ?? []
        let list = devices.filter(\.rings).compactMap { device in device.doorbellTag.map { (device.id, DoorbellRing(tag: $0)) } }
        guard !list.isEmpty, rings[key] != nil, endings[key] == nil else { return }
        for (deviceID, ring) in list { owners[ring.recordName] = RingOwner(key: key, deviceID: deviceID, at: now) }
        let all = list.map(\.1)
        rings[key] = all
        do {
            try await doorbell.ring(all)
        } catch {
            logger.error("The doorbell didn't ring")
        }
        // It ended (or the device went) while the records were being saved: take them back.
        let kept = Set((rings[key] ?? []).map(\.recordName))
        let late = all.filter { !kept.contains($0.recordName) }
        await remove(late)
    }

    private func end(_ key: Key, _ ending: Ending, now: Date) async {
        if endings[key] == nil || ending == .answered { endings[key] = (ending, now) }
        started[key] = nil
        if case let .access(id) = key { accessWaits[id] = nil }
        destinations[key.id] = nil
        let gone = rings.removeValue(forKey: key) ?? []
        await remove(gone)
    }

    private func remove(_ rings: [DoorbellRing]) async {
        guard !rings.isEmpty else { return }
        do { try await doorbell.remove(recordNames: rings.map(\.recordName)) } catch {
            logger.error("Couldn't delete doorbell records")
        }
    }

    private func agent(_ id: UUID?) async throws -> Agent? {
        guard let id else { return nil }
        return try await services.agents.agent(id: id)
    }

    private func log(_ event: String, device: UUID, now: Date, requestID: UUID? = nil, outcome: String = "ok",
                     counts: [String: Int] = [:]) {
        services.activity.record(ActivityEvent(time: now, requestID: requestID, phase: .event, actor: .device(device), via: .companion,
                                               event: event, outcome: outcome, counts: counts))
    }
}
