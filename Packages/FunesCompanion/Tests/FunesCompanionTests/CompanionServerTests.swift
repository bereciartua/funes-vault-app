import BridgeKitCore
import CryptoKit
import Foundation
@testable import FunesCore
import FunesProtocol
import Testing
@testable import FunesCompanion

/// The protocol test plan (companion-protocol §9), against the Mac's router and a real vault.
@Suite struct PairingFlowTests {
    @Test func happyPath() async throws {
        let h = try CompanionHarness()
        var phone = CompanionHarness.Phone()
        let (response, _) = try await h.pair(&phone, payload: await h.qr())
        #expect(response.status == 200)
        let id = try #require(phone.deviceID)
        let devices = try await h.services.devices.devices()
        #expect(devices.map(\.id) == [id])
        #expect(devices.first?.name == "Sam's iPhone")
        #expect(devices.first?.signingPublicKey == phone.signer.publicKey.x963Representation)
        #expect(await h.pairing.state == .paired(deviceName: "Sam's iPhone"))
    }

    @Test func expiredQR() async throws {
        let h = try CompanionHarness()
        let payload = await h.qr()
        h.clock.advance(301)
        var phone = CompanionHarness.Phone()
        let (response, _) = try await h.pair(&phone, payload: payload)
        #expect(response.status == 403)
        #expect(PairingError(body: response.body) == .expired)
    }

    @Test func wrongSecretThenAFourthAttempt() async throws {
        let h = try CompanionHarness()
        var guessed = await h.qr()
        guessed.secret = Data(repeating: 1, count: 32)
        for _ in 0..<3 {
            var phone = CompanionHarness.Phone()
            let (response, _) = try await h.pair(&phone, payload: guessed, allow: true)
            #expect(PairingError(body: response.body) == .invalidProof)
        }
        // The 4th attempt burns the session, even with the right secret.
        var phone = CompanionHarness.Phone()
        let (fourth, _) = try await h.pair(&phone, payload: guessed, allow: true)
        #expect(PairingError(body: fourth.body) == .tooManyAttempts)
        #expect(try await h.services.devices.devices().isEmpty)
    }

    @Test func deniedOnTheMacBurnsTheSecret() async throws {
        let h = try CompanionHarness()
        let payload = await h.qr()
        var phone = CompanionHarness.Phone()
        let (denied, _) = try await h.pair(&phone, payload: payload, allow: false)
        #expect(PairingError(body: denied.body) == .denied)
        // The same QR code can't be used again.
        let (again, _) = try await h.pair(&phone, payload: payload, allow: true)
        #expect(PairingError(body: again.body) == .expired)
        #expect(try await h.services.devices.devices().isEmpty)
    }

    @Test func aSecondQRReplacesTheFirst() async throws {
        let h = try CompanionHarness()
        let first = await h.qr()
        _ = await h.qr()
        var phone = CompanionHarness.Phone()
        let (response, _) = try await h.pair(&phone, payload: first)
        #expect(PairingError(body: response.body) == .expired)
    }

    @Test func atMostFiveDevices() async throws {
        let h = try CompanionHarness()
        for _ in 0..<5 { _ = try await h.pairedPhone() }
        var sixth = CompanionHarness.Phone()
        let (response, _) = try await h.pair(&sixth, payload: await h.qr())
        #expect(PairingError(body: response.body) == .tooManyDevices)
    }

    @Test func anUnansweredPromptIsADeny() async throws {
        let h = try CompanionHarness(promptTimeout: 0.2)
        var phone = CompanionHarness.Phone()
        let (client, body) = try PairingClient.start(payload: await h.qr(), deviceName: "Sam's iPhone", model: "iPhone17,1",
                                                     signer: phone.signer, deviceHPKEKey: phone.hpke, now: t0)
        _ = client
        let response = await h.router.handle(CompanionHarness.request(CompanionProtocol.pairPath, body: body), transport: .lan)
        #expect(PairingError(body: response.body) == .denied)
        phone.deviceID = nil
        #expect(try await h.services.devices.devices().isEmpty)
    }

    /// An earlier prompt's timeout never answers a later one.
    @Test func anOldTimeoutDoesntDenyANewPrompt() async throws {
        let h = try CompanionHarness(promptTimeout: 0.5)
        var first = CompanionHarness.Phone()
        _ = try await h.pair(&first, payload: await h.qr(), allow: true)
        // The first prompt's timer (0.5 s) is still running when a second pairing starts at 0.3 s;
        // at 0.65 s the first timer has fired and the second prompt must still be waiting.
        try await Task.sleep(for: .milliseconds(300))
        var second = CompanionHarness.Phone()
        let (_, body) = try PairingClient.start(payload: await h.qr(), deviceName: "Ana's iPhone", model: "iPhone17,1",
                                                signer: second.signer, deviceHPKEKey: second.hpke, now: t0)
        async let response = h.router.handle(CompanionHarness.request(CompanionProtocol.pairPath, body: body), transport: .lan)
        try await Task.sleep(for: .milliseconds(350))
        #expect(await h.pairing.isAsking)
        await h.pairing.answer(allow: true)
        #expect(await response.status == 200)
        second.deviceID = nil
    }

    @Test func badDeviceNamesAreRefused() async throws {
        let h = try CompanionHarness()
        var phone = CompanionHarness.Phone()
        let (response, _) = try await h.pair(&phone, payload: await h.qr(), name: "Evil\u{0007}Phone")
        #expect(PairingError(body: response.body) == .invalidRequest)
    }
}

@Suite struct EnvelopeRoutingTests {
    @Test func statusOverTheEnvelope() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let status = try await h.result(StatusGet.self, EmptyParams(), phone: phone)
        #expect(status.macName == "Maya's MacBook Pro")
        #expect(status.serverTime == t0)
        let device = try #require(try await h.services.devices.device(id: phone.deviceID!))
        #expect(device.lastTransport == .lan)
        #expect(device.lastSeenAt == t0)
    }

    @Test func unknownAndRevokedDevicesGet401() async throws {
        let h = try CompanionHarness()
        var stranger = CompanionHarness.Phone()
        stranger.deviceID = UUID()
        let (unknown, _) = try await h.call(StatusGet.self, EmptyParams(), phone: stranger)
        #expect(unknown.status == 401)
        #expect(CompanionAuthError(body: unknown.body) == .unknownDevice)

        let phone = try await h.pairedPhone()
        try await h.services.devices.revoke(deviceID: phone.deviceID!, now: t0, actor: .user)
        let (revoked, _) = try await h.call(StatusGet.self, EmptyParams(), phone: phone)
        #expect(CompanionAuthError(body: revoked.body) == .revoked)
    }

    @Test func replayAndSkew() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let request = try CompanionRequest(StatusGet.self, params: EmptyParams()).encoded()
        let sealed = try CompanionRequestEnvelope.seal(request, deviceID: phone.deviceID!, macHPKEKey: h.identity.hpkeKey.publicKey,
                                                       signer: phone.signer, now: t0)
        let http = CompanionHarness.request(CompanionProtocol.rpcPath, body: sealed.envelope.body)
        #expect(await h.router.handle(http, transport: .lan).status == 200)
        let replayed = await h.router.handle(http, transport: .lan)
        #expect(CompanionAuthError(body: replayed.body) == .replay)

        let (skewed, _) = try await h.call(StatusGet.self, EmptyParams(), phone: phone, at: t0.addingTimeInterval(-300))
        #expect(CompanionAuthError(body: skewed.body) == .clockSkew(serverTime: t0))
    }

    @Test func tamperedEnvelopeIsRefused() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let request = try CompanionRequest(StatusGet.self, params: EmptyParams()).encoded()
        let sealed = try CompanionRequestEnvelope.seal(request, deviceID: phone.deviceID!, macHPKEKey: h.identity.hpkeKey.publicKey,
                                                       signer: phone.signer, now: t0)
        var object = try #require(try JSONSerialization.jsonObject(with: sealed.envelope.body) as? [String: Any])
        var ct = Base64URL.decode(object["ct"] as! String)!
        ct[ct.startIndex] ^= 1
        object["ct"] = Base64URL.encode(ct)
        let body = try JSONSerialization.data(withJSONObject: object)
        let response = await h.router.handle(CompanionHarness.request(CompanionProtocol.rpcPath, body: body), transport: .lan)
        #expect(CompanionAuthError(body: response.body) == .invalidSignature)
    }

    @Test func httpRefusals() async throws {
        let h = try CompanionHarness()
        #expect(await h.router.handle(CompanionHarness.request("/c/v1/other", body: Data()), transport: .lan).status == 404)
        #expect(await h.router.handle(CompanionHarness.request(CompanionProtocol.rpcPath, body: Data(), method: "GET"),
                                      transport: .lan).status == 405)
        #expect(await h.router.handle(CompanionHarness.request(CompanionProtocol.rpcPath, body: Data(), contentType: "text/plain"),
                                      transport: .lan).status == 415)
        // A tunnel path off the tunnel, and a tunnel request without tunnel mode.
        #expect(await h.router.handle(CompanionHarness.request("/r/x/c/v1/rpc", body: Data()), transport: .lan).status == 404)
        #expect(await h.router.handle(CompanionHarness.request(CompanionProtocol.rpcPath, body: Data()), transport: .tunnel).status == 404)
    }

    /// Tunnel with the wrong path or Host (§9 reachability).
    @Test func tunnelGate() async throws {
        let gate = TunnelGate(secret: TunnelGate.newSecret(), publicHost: "maya.tailnet.ts.net")
        let h = try CompanionHarness(gate: gate)
        let phone = try await h.pairedPhone()
        let request = try CompanionRequest(StatusGet.self, params: EmptyParams()).encoded()
        func send(_ path: String, host: String) async throws -> HTTPResponse {
            let sealed = try CompanionRequestEnvelope.seal(request, deviceID: phone.deviceID!, macHPKEKey: h.identity.hpkeKey.publicKey,
                                                           signer: phone.signer, now: t0)
            return await h.router.handle(CompanionHarness.request(path, body: sealed.envelope.body, host: host), transport: .tunnel)
        }
        #expect(try await send("/r/\(gate.secret)/c/v1/rpc", host: "maya.tailnet.ts.net").status == 200)
        #expect(try await send("/c/v1/rpc", host: "maya.tailnet.ts.net").status == 404)
        #expect(try await send("/r/\(TunnelGate.newSecret())/c/v1/rpc", host: "maya.tailnet.ts.net").status == 404)
        #expect(try await send("/r/\(gate.secret)/c/v1/rpc", host: "evil.example").status == 421)
        let device = try #require(try await h.services.devices.device(id: phone.deviceID!))
        #expect(device.lastTransport == .tunnel)
    }

    @Test func unknownMethodIsAnErrorReply() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let plaintext = Data(#"{"id":"x","method":"vault.export","params":{}}"#.utf8)
        let sealed = try CompanionRequestEnvelope.seal(plaintext, deviceID: phone.deviceID!, macHPKEKey: h.identity.hpkeKey.publicKey,
                                                       signer: phone.signer, now: t0)
        let response = await h.router.handle(CompanionHarness.request(CompanionProtocol.rpcPath, body: sealed.envelope.body),
                                             transport: .lan)
        let reply = try CompanionResponse<EmptyResult>.decode(try sealed.responseKey.open(response.body))
        #expect(reply.id == "x")
        #expect(reply.error?.code == .unknownMethod)
    }
}

@Suite struct CompanionMethodTests {
    func capture(_ text: String, id: UUID = UUID()) -> CompanionCapture {
        CompanionCapture(captureId: id, text: text, createdAt: t0, source: .typed)
    }

    @Test func capturesAreExactlyOnce() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let id = UUID()
        let first = try await h.result(CapturesSubmit.self, CapturesSubmitParams(captures: [capture("Buy oat milk", id: id)]), phone: phone)
        #expect(first.accepted == [id])
        // The reply was "lost"; the phone resends: accepted again, nothing new stored.
        let again = try await h.result(CapturesSubmit.self, CapturesSubmitParams(captures: [capture("Buy oat milk", id: id)]), phone: phone)
        #expect(again.accepted == [id])
        let pending = try await h.services.suggestions.pending()
        #expect(pending.count == 1)
        #expect(pending.first?.origin == .captureIPhone)
        #expect(pending.first?.deviceID == phone.deviceID)
    }

    @Test func secretsAndBadCapturesAreRejectedOneByOne() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let good = capture("Ana's birthday is 3 May"), secret = capture("key AKIA" + String(repeating: "B", count: 16)),
            empty = capture("   ")
        let result = try await h.result(CapturesSubmit.self, CapturesSubmitParams(captures: [good, secret, empty]), phone: phone)
        #expect(result.accepted == [good.captureId])
        #expect(result.rejected == [CaptureRejection(captureId: secret.captureId, reason: .secretLikeContent),
                                    CaptureRejection(captureId: empty.captureId, reason: .invalidInput)])
    }

    @Test func moreThanFiftyIsInvalid() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let many = (0..<51).map { capture("Note \($0)") }
        await #expect(throws: CompanionError.self) {
            try await h.result(CapturesSubmit.self, CapturesSubmitParams(captures: many), phone: phone)
        }
    }

    @Test func searchGetEditWithVersions() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let created = try await h.result(MemoriesCreate.self, MemoryCreateParams(
            title: "Coffee", body: "Oat flat white, no sugar", kind: .preference, categories: ["personal_preferences"],
            sensitivity: .low), phone: phone)
        #expect(created.version == 1)

        let found = try await h.result(MemoriesSearch.self, MemorySearchParams(query: "coffee"), phone: phone)
        #expect(found.results.map(\.id) == [created.id])
        #expect(found.results.first?.snippet == "Oat flat white, no sugar")

        let detail = try await h.result(MemoriesGet.self, MemoryID(id: created.id), phone: phone)
        #expect(detail.memory.body == "Oat flat white, no sugar")
        #expect(detail.provenance.first?.label == "Sam's iPhone")
        #expect(detail.sharedCount == 0)

        let edited = try await h.result(MemoriesUpdate.self, MemoryUpdateParams(id: created.id, version: 1,
                                                                                changes: MemoryChanges(body: "Oat flat white")), phone: phone)
        #expect(edited.version == 2)
        // "Changed on your Mac, reload?": a stale version is a conflict, and nothing changes.
        await #expect(throws: CompanionError(.conflict)) {
            try await h.result(MemoriesUpdate.self, MemoryUpdateParams(id: created.id, version: 1,
                                                                       changes: MemoryChanges(title: "Tea")), phone: phone)
        }
        #expect(try h.store.memory(id: created.id)?.title == "Coffee")

        let archived = try await h.result(MemoriesArchive.self, MemoryVersionRef(id: created.id, version: 2), phone: phone)
        await #expect(throws: CompanionError(.conflict)) {
            try await h.result(MemoriesRestore.self, MemoryVersionRef(id: created.id, version: 2), phone: phone)
        }
        let restored = try await h.result(MemoriesRestore.self, MemoryVersionRef(id: created.id, version: archived.version), phone: phone)
        _ = try await h.result(MemoriesDelete.self, MemoryVersionRef(id: created.id, version: restored.version), phone: phone)
        #expect(try h.store.memory(id: created.id)?.status == .deleted)
        await #expect(throws: CompanionError(.notFound)) {
            try await h.result(MemoriesGet.self, MemoryID(id: UUID()), phone: phone)
        }
    }

    @Test func secretsCantBeSavedFromThePhone() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        await #expect(throws: CompanionError(.secretLikeContent, findings: [.awsAccessKey])) {
            try await h.result(MemoriesCreate.self, MemoryCreateParams(
                title: "Keys", body: "AKIA" + String(repeating: "C", count: 16), kind: .fact, categories: ["software_development"],
                sensitivity: .secret), phone: phone)
        }
    }

    @Test func inboxApplyAndReject() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let a = capture("Ana's birthday is 3 May"), b = capture("Gym on Tuesdays")
        _ = try await h.result(CapturesSubmit.self, CapturesSubmitParams(captures: [a, b]), phone: phone)
        let inbox = try await h.result(InboxList.self, InboxListParams(), phone: phone)
        #expect(inbox.items.count == 2)
        #expect(inbox.items.allSatisfy { $0.sourceLabel == "Sam's iPhone" })
        let applied = try await h.result(InboxApply.self, InboxApplyParams(suggestionId: inbox.items[0].id,
                                                                           edits: MemoryChanges(title: "Ana's birthday")), phone: phone)
        #expect(try h.store.memory(id: applied.memoryId)?.title == "Ana's birthday")
        _ = try await h.result(InboxReject.self, SuggestionID(suggestionId: inbox.items[1].id), phone: phone)
        #expect(try await h.services.suggestions.pending().isEmpty)
        #expect(try await h.result(StatusGet.self, EmptyParams(), phone: phone).inboxPending == 0)
    }

    /// A capture New memories processing hasn't finished with is listed as `processing`, can't be
    /// saved (`processing`), only rejected; a failed split is `failed`, with Try again and Keep as
    /// one (memory processing §5.2). With splitting off nothing waits.
    @Test func inboxItemsWaitForProcessing() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let a = capture("Ana's birthday is 3 May"), b = capture("Gym on Tuesdays")
        _ = try await h.result(CapturesSubmit.self, CapturesSubmitParams(captures: [a, b]), phone: phone)
        #expect(try await h.result(InboxList.self, InboxListParams(), phone: phone).items.allSatisfy { $0.processing == nil })

        h.services.suggestions.splitting.set(true)
        var items = try await h.result(InboxList.self, InboxListParams(), phone: phone).items
        #expect(items.allSatisfy { $0.processing == .processing })
        let ana = try #require(items.first { $0.body.hasPrefix("Ana") }).id
        let gym = try #require(items.first { $0.body.hasPrefix("Gym") }).id
        await #expect(throws: CompanionError(.processing)) {
            try await h.result(InboxApply.self, InboxApplyParams(suggestionId: ana), phone: phone)
        }
        // Reject is allowed, and cancels the job.
        _ = try await h.result(InboxReject.self, SuggestionID(suggestionId: gym), phone: phone)
        let queue = ProcessingQueue(store: h.store, activity: h.activity)
        #expect(try await queue.job(subject: gym)?.state == .done)

        // The split failed: Try again, then Keep as one.
        func fail() throws {
            try h.store.writer.write { db in
                try db.execute(sql: "UPDATE processing_job SET state = 'failed', error = 'timeout' WHERE subject = ?", arguments: [ana.db])
            }
        }
        try fail()
        items = try await h.result(InboxList.self, InboxListParams(), phone: phone).items
        #expect(items.map(\.processing) == [.failed])
        _ = try await h.result(InboxRetry.self, SuggestionID(suggestionId: ana), phone: phone)
        #expect(try await h.result(InboxList.self, InboxListParams(), phone: phone).items.map(\.processing) == [.processing])
        await #expect(throws: CompanionError(.conflict)) {
            try await h.result(InboxKeep.self, SuggestionID(suggestionId: ana), phone: phone)
        }
        try fail()
        _ = try await h.result(InboxKeep.self, SuggestionID(suggestionId: ana), phone: phone)
        #expect(try await h.result(InboxList.self, InboxListParams(), phone: phone).items.map(\.processing) == [nil])
        _ = try await h.result(InboxApply.self, InboxApplyParams(suggestionId: ana), phone: phone)
        #expect(try await h.services.suggestions.pending().isEmpty)
    }

    /// Task 6.1.1/6.1.7: `inbox.apply` applies each suggestion as its own action, refuses a
    /// changed target with `target_changed`, and leaves merge, split and conflict to the Mac, and
    /// the tidy-up's proposals too (ADR-0021).
    @Test func inboxApplyIsPerAction() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let old = try h.store.createMemory(MemoryDraft(title: "Editor", body: "Uses Vim", categoryKeys: ["software_development"]), now: t0)
        let dup = try h.store.createMemory(MemoryDraft(title: "Copy", body: "Copy body", categoryKeys: ["personal_preferences"]), now: t0)
        func suggest(_ action: SuggestionAction, target: UUID? = nil, targets: [(UUID, SuggestionTarget.Role)] = [],
                     origin: SuggestionOrigin = .agent) throws -> UUID {
            try h.store.writer.write { db in
                try SuggestionService.insertSuggestion(
                    db, origin: origin, action: action,
                    input: SuggestInput(title: "Editor", body: "Uses Zed", categories: ["software_development"], targetMemoryID: target),
                    categories: ["software_development"], sensitivity: .low, targets: targets, now: t0)
            }
        }
        let update = try suggest(.update, target: old.id)
        let archive = try suggest(.archive, target: dup.id)
        let merge = try suggest(.merge, targets: [(old.id, .source), (dup.id, .source)])
        let tidied = try suggest(.archive, target: old.id, origin: .consolidation)
        let items = try await h.result(InboxList.self, InboxListParams(), phone: phone).items
        #expect(items.first { $0.id == update }?.targetMemoryVersion == 1)
        #expect(items.first { $0.id == merge }?.action == .merge)
        #expect(items.first { $0.id == tidied }?.action == .unknown)  // "Review on your Mac"
        await #expect(throws: CompanionError(.unsupportedAction)) {
            try await h.result(InboxApply.self, InboxApplyParams(suggestionId: tidied), phone: phone)
        }
        try await h.services.suggestions.reject(suggestionID: tidied, now: t0)

        let archived = try await h.result(InboxApply.self, InboxApplyParams(suggestionId: archive), phone: phone)
        #expect(try archived.memoryId == dup.id && h.store.memory(id: dup.id)?.status == .archived)
        #expect(try h.store.memories(now: t0).count == 1)
        await #expect(throws: CompanionError(.unsupportedAction)) {
            try await h.result(InboxApply.self, InboxApplyParams(suggestionId: merge), phone: phone)
        }

        try h.store.updateMemory(id: old.id, MemoryEdit(body: "Uses Helix"), now: t0)
        await #expect(throws: CompanionError(.targetChanged)) {
            try await h.result(InboxApply.self, InboxApplyParams(suggestionId: update), phone: phone)
        }
        try await h.services.suggestions.reviewAgain(suggestionID: update)
        let replaced = try await h.result(InboxApply.self, InboxApplyParams(suggestionId: update), phone: phone)
        #expect(try replaced.memoryId == old.id && h.store.memory(id: old.id)?.body == "Uses Zed")
    }

    /// Every call is under `device:<id>` in Activity (task 5.2), except the status probe.
    @Test func activityRowsAreUnderTheDevice() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let before = h.activity.events.count
        _ = try await h.result(StatusGet.self, EmptyParams(), phone: phone)
        _ = try await h.result(CapturesSubmit.self, CapturesSubmitParams(captures: [capture("Hello there")]), phone: phone)
        _ = try await h.result(MemoriesSearch.self, MemorySearchParams(query: ""), phone: phone)
        _ = try await h.result(CategoriesList.self, EmptyParams(), phone: phone)
        let rows = h.activity.events.dropFirst(before)
        let actor = "device:\(phone.deviceID!.uuidString.lowercased())"
        #expect(rows.map(\.event) == ["capture", "memories_searched", "categories_listed"])
        #expect(rows.allSatisfy { $0.actor == actor && $0.via == .companion })
    }

    @Test func unpairRevokesTheDevice() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        _ = try await h.result(DeviceUnpair.self, EmptyParams(), phone: phone)
        let (after, _) = try await h.call(StatusGet.self, EmptyParams(), phone: phone)
        #expect(CompanionAuthError(body: after.body) == .revoked)
    }

    @Test func callsAreRateLimited() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        for _ in 0..<DeviceLimits.callsPerMinute { _ = try await h.call(CategoriesList.self, EmptyParams(), phone: phone) }
        await #expect(throws: CompanionError.self) {
            try await h.result(StatusGet.self, EmptyParams(), phone: phone)
        }
        let (_, reply) = try await h.call(StatusGet.self, EmptyParams(), phone: phone)
        #expect(reply?.error?.code == .rateLimited)
        #expect((reply?.error?.retryAfterSeconds ?? 0) > 0)
    }
}
