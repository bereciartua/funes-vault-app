import Foundation

/// What a phone can show, sent in each request's plaintext as `caps` (v0.10, §3). The Mac decides per call from the caps
/// that call carries; an unknown capability is ignored.
public enum CompanionCapability {
    /// The phone shows learned facts as ADR-0032 requires: why lines on results, inferred claims marked with their basis,
    /// and **Not <name>** and **Not this** (`facts.reject`).
    public static let facts = "facts"

    /// The phone shows People & history, read from the Mac (13d.2, §4.3): `people.*`, and `status.get`'s `people`.
    public static let people = "people"

    /// The phone shows answers the time model checked (13e.2, §3): the Mac's line in place of a claim's text, "not sure",
    /// and "text you didn't write says otherwise". Without it, `memories.answer` reads no rows, so no claim owes a check.
    public static let checked = "checked"

    /// What this build sends on every call.
    public static let current = [facts, people, checked]
}

/// One correction a result's why line or an answer's inferred claim offers (§4, memory processing §11.8): **Not <name>**
/// (`name`, a `linkId`) or **Not this** (`fact` with a `factId`; `order` with an `orderId`). A target with `memoryId` is
/// keyed to that memory and its quoted spans; without one, it rejects the fact everywhere. `token` is minted by the Mac
/// for that target and binds it to the evidence it rested on; `label` is what the button says, worded on the Mac.
public struct FactsCorrectionTarget: Codable, Sendable, Hashable {
    public enum What: String, Codable, Sendable {
        case name, fact, order
        /// A kind a newer Mac sends that this build doesn't know: decoded (so the rest of the result still reads), never
        /// shown and never sent back.
        case unknown

        public init(from decoder: any Decoder) throws {
            self = What(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var what: What
    public var linkID: String?
    public var factID: String?
    public var orderID: String?
    public var memoryID: UUID?
    public var token: String
    /// "Not Maria", "Not this": shown as is; ignored by `facts.reject`.
    public var label: String?

    public init(what: What, linkID: String? = nil, factID: String? = nil, orderID: String? = nil, memoryID: UUID? = nil,
                token: String, label: String? = nil) {
        self.what = what
        self.linkID = linkID
        self.factID = factID
        self.orderID = orderID
        self.memoryID = memoryID
        self.token = token
        self.label = label
    }

    enum CodingKeys: String, CodingKey {
        case what, token, label
        case linkID = "linkId"
        case factID = "factId"
        case orderID = "orderId"
        case memoryID = "memoryId"
    }

    /// Exactly one id, of the kind `what` needs, and a token.
    public func validate() throws(CompanionError) {
        let ids = [linkID, factID, orderID].compactMap { $0 }
        guard ids.count == 1 else { throw CompanionError(.invalidInput, message: "One id") }
        let ok = switch what {
        case .name: linkID != nil
        case .fact: factID != nil
        case .order: orderID != nil
        case .unknown: false
        }
        guard ok, !token.isEmpty, token.count <= 64, ids[0].count <= 200 else { throw CompanionError(.invalidInput, message: "Bad target") }
    }
}

/// `facts.reject` (v0.10): one correction target, as a result or claim carried it. Needs the `facts` capability.
public enum FactsReject: CompanionCall {
    public static let method = CompanionMethod.factsReject
    public typealias Params = FactsCorrectionTarget
    public typealias Result = FactsRejectResult
}

public struct FactsRejectResult: Codable, Sendable, Equatable {
    /// Search's revision while *Use in search and answers* is on, else People's (13d.2).
    public var factsRevision: String
    /// People & history's revision (13d.2), while People is open for this phone.
    public var peopleRevision: String?

    public init(factsRevision: String, peopleRevision: String? = nil) {
        self.factsRevision = factsRevision
        self.peopleRevision = peopleRevision
    }
}
