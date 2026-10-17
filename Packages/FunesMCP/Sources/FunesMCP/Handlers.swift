import BridgeKitCore
import Foundation
import FunesCore
import FunesProtocol

// The five tool handlers (mcp-server.md §6). Arguments already passed the contract's schema;
// FunesCore re-checks every limit (fail closed) and makes every decision.

extension RequestPipeline {
    // MARK: list_memory_categories

    /// The categories and what this agent may do in each. No memory counts: they would leak
    /// information about the vault (§6.1).
    func listCategories(_ call: ToolCall, _ agent: Agent) -> ToolResult {
        let categories: [MemoryCategory]
        do { categories = try services.store.categories() } catch { return refuse(call, agent.id, .notFound) }
        let access = agent.access
        let reads = access.operations.contains(.read)
        let suggests = access.operations.contains(.suggest) || access.operations.contains(.write)
        func inScope(_ key: String) -> Bool {
            !access.deniedCategoryKeys.contains(key)
                && (access.allowedCategoryKeys.isEmpty || access.allowedCategoryKeys.contains(key))
        }
        let rows: [[String: Any]] = categories.map { category in
            ["key": category.key, "name": category.name, "description": category.description,
             "can_read": reads && inScope(category.key), "can_suggest": suggests && inScope(category.key)]
        }
        record(call, agent.id, outcome: "listed")
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return ToolOutput.make(["categories": rows, "max_sensitivity": access.maxSensitivity.name,
                                "asks_before_sharing": access.askBeforeSharing, "now": formatter.string(from: now())])
    }

    // MARK: request_memory

    func requestMemory(_ call: ToolCall, _ agent: Agent) async -> ToolResult {
        let a = call.arguments
        let input = MemoryRequest(
            task: a["task"] as? String ?? "",
            keywords: a["keywords"] as? [String] ?? [],
            purpose: a["purpose"] as? String,
            categories: a["categories"] as? [String] ?? [],
            maxTokens: (a["max_tokens"] as? NSNumber)?.intValue ?? InputLimits.defaultMaxTokens,
            retention: (a["retention"] as? String).flatMap(Retention.init(rawValue:)) ?? .unknown,
            processors: a["processors"] as? [String] ?? [])
        let presenter = self.presenter
        do {
            // Requests waiting for the user: at most 3 per agent (§9), counted by FunesCore in the
            // write that would add one, so concurrent calls can't all pass.
            let outcome = try await services.disclosures.requestInCall(
                agentID: agent.id, input, wait: inCallWait, maxPendingApprovals: Self.maxPendingApprovalsPerAgent,
                now: now,
                onNeedsApproval: { outcome in
                    guard let id = outcome.requestID else { return }
                    Task { await presenter.showApproval(requestID: id, agentID: agent.id) }
                })
            if outcome.status == .denied, outcome.reason == .rateLimited {
                // FunesCore recorded it in Activity; the agent gets the usual infrastructure answer.
                return ToolOutput.denied(.rateLimited, message: Messages.rateLimited(Self.pendingRetrySeconds),
                                         isError: true, extra: ["retry_after_s": Self.pendingRetrySeconds])
            }
            return Self.output(outcome)
        } catch let error as VaultError {
            return failure(call, agent.id, error)
        } catch {
            return refuse(call, agent.id, .notFound)
        }
    }

    // MARK: get_memory_request

    func getMemoryRequest(_ call: ToolCall, _ agent: Agent) async -> ToolResult {
        let text = call.arguments["request_id"] as? String ?? ""
        guard let requestID = UUID(uuidString: text) else {
            // Not an id Funes made: the same answer as another agent's request (T20).
            record(call, agent.id, outcome: "not_found", reason: .notFound)
            return ToolOutput.make(["status": "not_found", "request_id": text, "reason": ReasonCode.notFound.rawValue,
                                    "message": Messages.text(for: .notFound), "max_tokens": 0])
        }
        // Once per 5 s per request id (§6.3).
        let current = now()
        let key = agent.id.uuidString + "|" + requestID.uuidString
        let wait = lastGet.withLock { last -> Int? in
            if let previous = last[key], current.timeIntervalSince(previous) < Self.getMemoryRequestInterval {
                return max(1, Int((Self.getMemoryRequestInterval - current.timeIntervalSince(previous)).rounded(.up)))
            }
            last = last.filter { current.timeIntervalSince($0.value) < 60 }
            last[key] = current
            return nil
        }
        if let wait { return rateLimited(call, agent.id, wait) }
        do {
            return Self.output(try await services.disclosures.deliver(requestID: requestID, agentID: agent.id, now: current))
        } catch let error as VaultError {
            return failure(call, agent.id, error)
        } catch {
            return refuse(call, agent.id, .notFound)
        }
    }

    /// The §6.2 output for a `RequestOutcome`.
    static func output(_ outcome: RequestOutcome) -> ToolResult {
        var object: [String: Any] = ["status": outcome.status.rawValue]
        let requestID = outcome.requestID?.uuidString.lowercased()
        if let requestID { object["request_id"] = requestID }
        if let reason = outcome.reason { object["reason"] = reason.rawValue }
        switch outcome.status {
        case .delivered, .fulfilled:
            let bundle = outcome.bundle
            let items = bundle?.items ?? []
            object["items"] = items.map { item -> [String: Any] in
                ["memory_id": item.memoryID.uuidString.lowercased(), "title": item.title, "text": item.text,
                 "category": item.category, "sensitivity": item.sensitivity.name,
                 "estimated_tokens": item.estimatedTokens, "clipped": item.clipped]
            }
            object["estimated_tokens"] = bundle?.estimatedTokens ?? 0
            object["instructions"] = bundle?.instructions ?? BundleCompiler.instructions
            object["message"] = Messages.delivered(items.count)
        case .needsApproval:
            object["message"] = Messages.needsApproval(requestID ?? "")
        case .denied, .alreadyDelivered, .notFound:
            object["message"] = Messages.text(for: outcome.reason ?? .notFound)
        }
        object["max_tokens"] = outcome.maxTokens
        if let withheld = outcome.withheld {
            object["withheld"] = Dictionary(uniqueKeysWithValues: withheld.map { ($0.key.rawValue, $0.value) })
        }
        return ToolOutput.make(object)
    }

    // MARK: suggest_memory

    func suggestMemory(_ call: ToolCall, _ agent: Agent) async -> ToolResult {
        let a = call.arguments
        var metadataJSON: String?
        if let metadata = a["metadata"] {
            guard let data = try? JSONSerialization.data(withJSONObject: metadata,
                                                         options: [.sortedKeys, .withoutEscapingSlashes]),
                  data.count <= InputLimits.callerMetadataBytes else {
                return refuse(call, agent.id, .invalidInput, message: "metadata: must be at most 4 KiB as JSON")
            }
            metadataJSON = String(decoding: data, as: UTF8.self)
        }
        var expiresAt: Date?
        if let text = a["expires_at"] as? String {
            guard let date = Self.date(text) else {
                return refuse(call, agent.id, .invalidInput,
                              message: "expires_at: expected an ISO 8601 date-time like 2027-01-31T09:00:00Z")
            }
            expiresAt = date
        }
        var target: UUID?
        if let text = a["target_memory_id"] as? String {
            guard let id = UUID(uuidString: text) else { return refuse(call, agent.id, .notFound) }
            target = id
        }
        let input = SuggestInput(
            title: a["title"] as? String ?? "", body: a["body"] as? String ?? "",
            kind: (a["kind"] as? String).flatMap(MemoryKind.init(rawValue:)),
            categories: a["categories"] as? [String] ?? [],
            sensitivity: (a["sensitivity"] as? String).flatMap(Sensitivity.init(name:)),
            evidence: a["evidence"] as? String, purpose: a["purpose"] as? String, expiresAt: expiresAt,
            confidence: (a["confidence"] as? NSNumber)?.doubleValue, targetMemoryID: target, metadataJSON: metadataJSON)
        let outcome: SuggestOutcome
        do {
            outcome = try await services.suggestions.suggest(agentID: agent.id, input, now: now())
        } catch let error as VaultError {
            return failure(call, agent.id, error)
        } catch {
            return refuse(call, agent.id, .notFound)
        }
        var object: [String: Any] = ["status": outcome.status.rawValue]
        switch outcome.status {
        case .saved:
            limiter.recordWrite(agent.id.uuidString.lowercased())
            object["memory_id"] = outcome.memoryID?.uuidString.lowercased()
            object["message"] = "Saved to the user's Funes vault."
        case .queued:
            limiter.recordWrite(agent.id.uuidString.lowercased())
            object["suggestion_id"] = outcome.suggestionID?.uuidString.lowercased()
            object["message"] = "Saved to the user's Funes Inbox for review."
            if let id = outcome.suggestionID {
                let presenter = self.presenter
                Task { await presenter.showSuggestion(suggestionID: id, agentID: agent.id) }
            }
        case .denied:
            let reason = outcome.reason ?? .invalidInput
            object["reason"] = reason.rawValue
            object["message"] = Messages.text(for: reason)
            if !outcome.findings.isEmpty { object["findings"] = outcome.findings.map(\.rawValue) }
        }
        return ToolOutput.make(object)
    }

    /// ISO 8601 with an offset, with or without fractional seconds.
    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    // MARK: open_in_funes

    /// Only this agent's own pending request or suggestion can be opened; anything else is
    /// `not_found`, the same answer for another agent's item as for none (T20).
    func openInFunes(_ call: ToolCall, _ agent: Agent) async -> ToolResult {
        let notFound = ToolOutput.make(["opened": false, "reason": ReasonCode.notFound.rawValue])
        if let text = call.arguments["request_id"] as? String {
            guard let id = UUID(uuidString: text),
                  let disclosure = try? await services.disclosures.disclosure(requestID: id),
                  disclosure.agentID == agent.id,
                  [.needsApproval, .approved].contains(disclosure.status) else {
                record(call, agent.id, outcome: "not_found", reason: .notFound)
                return notFound
            }
            await presenter.open(requestID: id)
        } else if let text = call.arguments["suggestion_id"] as? String {
            guard let id = UUID(uuidString: text),
                  let suggestion = try? await services.suggestions.suggestion(id: id),
                  suggestion.agentID == agent.id, suggestion.status == .pending else {
                record(call, agent.id, outcome: "not_found", reason: .notFound)
                return notFound
            }
            await presenter.open(suggestionID: id)
        } else {
            return refuse(call, agent.id, .invalidInput, message: "Pass request_id or suggestion_id.")
        }
        record(call, agent.id, outcome: "opened")
        return ToolOutput.make(["opened": true])
    }

    // MARK: Errors

    /// FunesCore's errors as tool results. `invalidInput` names the field, never its text.
    func failure(_ call: ToolCall, _ agentID: UUID, _ error: VaultError) -> ToolResult {
        switch error {
        case .invalidInput(let field):
            return refuse(call, agentID, .invalidInput, message: "\(field): isn't valid")
        case .unauthenticated, .notFound:
            return refuse(call, agentID, .notFound)
        default:
            return refuse(call, agentID, .notFound, message: "Funes Vault couldn't complete this request. Try again later.")
        }
    }
}
