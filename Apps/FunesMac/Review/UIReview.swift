#if FUNES_UI_REVIEW
import AppKit
import BridgeKitCore
import BridgeKitRemote
import BridgeUI
@_spi(FactsReview) import FunesCore
import FunesMCP
import FunesProtocol
import SwiftUI

// The UI-review build (task 3.10, built by scripts/ui_snapshots.sh with FUNES_UI_REVIEW): a
// throwaway vault in a temporary folder filled with SampleData, its own user-defaults suite and an
// in-memory key store. It never opens the real vault, starts the MCP server, touches the Keychain
// or writes agents' configs (one-click previews read a scratch home).
//
// `--ui-snapshots <dir>` shows every main screen, sheet and panel in light and then dark. For each
// it prints {"ready": name, "windowNumber": n} and waits for a line on stdin while the script
// captures that window with screencapture; at the end it prints {"outcome": "passed", "files": [...]}.
@MainActor
final class UIReview: NSObject, NSApplicationDelegate {
    static func handles(_ arguments: [String]) -> Bool { arguments.contains("--ui-snapshots") }

    private var folder = URL(fileURLWithPath: NSTemporaryDirectory())
    private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("funes-ui-review-\(UUID().uuidString)")
    private let suiteName = "funes-ui-review-\(UUID().uuidString)"
    private var files: [String] = []
    private var windows: [NSWindow] = []
    private var keep: [AnyObject] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--ui-snapshots"), index + 1 < arguments.count {
            folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = NSMenu()
        Task {
            do {
                try await run()
                emit(["outcome": "passed", "files": files])
            } catch {
                emit(["outcome": "failed", "error": String(describing: error)])
            }
            cleanUp()
            NSApp.terminate(nil)
        }
    }

    // MARK: The fake app

    private struct Fixture {
        let model: AppModel
        let empty: AppModel
        let agents: SampleData.Agents
        let claudeDesktop: Agent
        let cloudAgent: Agent
        let shareItem: PanelItem
        let remoteShareItem: PanelItem
    }

    private func makeFixture() async throws -> Fixture {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let defaults = UserDefaults(suiteName: suiteName)!
        let preferences = Preferences(defaults: defaults)
        // Splitting on, so the sample capture being split shows "Processing…".
        preferences.splitNewMemories = true
        let environment = try VaultEnvironment(dataFolder: scratch.appendingPathComponent("vault"))
        let agents = try await SampleData.fill(environment)
        Self.recordFactsActivity(environment.activity)
        let (claudeDesktop, _) = try await environment.agents.create(name: "Claude Desktop", kind: .claudeDesktop,
                                                                     access: agents.claudeCode.access, now: Date())
        // A cloud agent with cloud access and a remote token (Remote Access, ADR-0018).
        let (claudeAI, _) = try await environment.agents.create(name: "claude.ai", kind: .claudeAI,
                                                                access: Access.Preset.readLowAskFirst.access, now: Date())
        try await environment.agents.setCloudAccess(agentID: claudeAI.id, true, now: Date())
        _ = try await environment.agents.issueRemoteKey(agentID: claudeAI.id, now: Date())
        // Claude Desktop's config as it ships: an empty mcpServers next to its own settings, in the
        // scratch home the one-click previews read.
        let desktopFolder = scratch.appendingPathComponent("home/Library/Application Support/Claude")
        try FileManager.default.createDirectory(at: desktopFolder, withIntermediateDirectories: true)
        try Data("""
            {
              "mcpServers": {},
              "coworkUserFilesPath": "/Users/you/Claude",
              "preferences": { "menuBarEnabled": true, "sidebarMode": "chat" }
            }
            """.utf8).write(to: desktopFolder.appendingPathComponent("claude_desktop_config.json"))
        // Claude Code connected through a request; a second one waits for the user.
        _ = try await environment.disclosures.request(agentID: agents.claudeCode.id,
                                                      MemoryRequest(task: "Which test framework does the user prefer?",
                                                                    keywords: ["vitest"]), now: Date().addingTimeInterval(-600))
        let waiting = try await environment.disclosures.request(
            agentID: agents.claudeCode.id,
            MemoryRequest(task: "Set up a new TypeScript repo following the user's preferences",
                          keywords: ["package manager", "test framework", "conventions"], purpose: "scaffold project",
                          retention: .session),
            now: Date().addingTimeInterval(-120))
        // Settings ▸ AI's review data (Phase 11.6): an API account with two models, the Claude plan
        // with two, a different model per job, and a local server.
        let settings = ModelSettings(defaults: defaults, keys: InMemoryProviderKeyStore())
        settings.upsert(AIAccount(endpoint: .ollama(), name: "Ollama", models: ["llama3.2"]))
        settings.upsert(AIAccount(endpoint: .anthropic(), name: "Anthropic", models: [AnthropicClient.suggestedModel, "claude-opus-5-5"]))
        try settings.setKey("review", for: "anthropic")
        settings.setChoice(.model(ModelChoice(account: "anthropic", model: AnthropicClient.suggestedModel)), for: .newMemories)
        settings.setChoice(.model(ModelChoice(account: "claude-code", model: "opus")), for: .tidyUp)
        settings.setChoice(.model(ModelChoice(account: "anthropic", model: "claude-opus-5-5")), for: .searchAnswers)
        settings.addUsage(ProviderUsage(requests: 412, inputTokens: 1_203_550, outputTokens: 80_112), for: "anthropic")
        settings.addUsage(ProviderUsage(requests: 9, inputTokens: 31_400, outputTokens: 2_050), for: "claude-code")
        settings.reviewPlans([.claudeCode: "/usr/local/bin/claude"], [.claudeCode: .ready(version: "2.1.310"), .codex: .notInstalled])
        // Search answers on, so the Vault shows the Ask row and Settings its page (FR-AI-17).
        settings.searchAnswersOn = true
        let model = AppModel(services: environment, preferences: preferences, modelSettings: settings)
        configure(model)
        await model.refresh()
        await model.activity.load()

        let panel = try await environment.disclosures.panel(requestID: waiting.requestID!, now: Date())!
        let disclosure = try await environment.disclosures.disclosure(requestID: waiting.requestID!)
        var share = FunesApprovals.shareItem(panel, withheld: disclosure?.withheld ?? [:], now: Date(),
                                             agent: agents.claudeCode, profileFields: disclosure?.profileFieldsSent ?? [])
        share.expiresAt = Date().addingTimeInterval(41.5)
        // The same request from a cloud agent through the tunnel (Goes to names the vendor).
        var cloudPanel = panel
        cloudPanel.agentName = claudeAI.name
        var remoteShare = FunesApprovals.shareItem(cloudPanel, withheld: [:], now: Date(), agent: claudeAI, remote: true,
                                                   tunnel: TunnelProvider.tailscaleFunnel.name)
        remoteShare.expiresAt = Date().addingTimeInterval(41.5)

        let emptyDefaults = UserDefaults(suiteName: suiteName + "-empty")!
        let emptyEnvironment = try VaultEnvironment(dataFolder: scratch.appendingPathComponent("empty"), embeddings: false)
        let empty = AppModel(services: emptyEnvironment, preferences: Preferences(defaults: emptyDefaults),
                             modelSettings: ModelSettings(defaults: emptyDefaults, keys: InMemoryProviderKeyStore()))
        configure(empty)
        await empty.refresh()
        let cloudAgent = try await environment.agents.agent(id: claudeAI.id) ?? claudeAI
        return Fixture(model: model, empty: empty, agents: agents, claudeDesktop: claudeDesktop, cloudAgent: cloudAgent,
                       shareItem: share, remoteShareItem: remoteShare)
    }

    private func configure(_ model: AppModel) {
        model.mcpStatus = .listening(port: 47_625)
        model.detectAgents = { [.claudeCode, .claudeDesktop, .cursor, .codex] }
        let home = scratch.appendingPathComponent("home").path
        model.setupControls = OneClickAgents.live(home: home, appName: "Funes Vault", tag: "funes",
                                                  locator: ExecutableLocator(isExecutable: { _ in false }, loginShellLookup: { _ in nil }))
        model.openMainWindow = {}
        model.openSettings = { _ in }
    }

    // MARK: Scenes

    private func run() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try await makeFixture()
        let model = fixture.model
        let main = MainWindowController(model: model)
        keep.append(main)
        // Made now, so the first pass's resize below applies to it too.
        main.show()
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            // Both passes start alike: the default window size, not the frame the real app autosaved,
            // and Remote Access off, as the previous pass leaves it on.
            main.window?.setContentSize(NSSize(width: 1_040, height: 680))
            model.remoteAccess.reviewSet(enabled: false, origin: nil, tunnel: nil)

            // The main window, section by section.
            func mainScene(_ name: String, _ prepare: () -> Void) async {
                prepare()
                main.show()
                await snapshot("\(name)-\(suffix)", main.window)
            }
            // Home (task 7.3): with the setup checklist on top, then as the user lives with it.
            await mainScene("home-checklist") {
                model.checklist.reset(model: model)
                model.section = .home
            }
            await mainScene("home") { model.checklist.dismiss() }
            await mainScene("vault-memory") {
                model.section = .vault
                model.vault.status = .active
                model.vault.selection = model.vault.memories.first(where: { $0.title == "Commit messages" }).map { [$0.id] } ?? []
            }
            // Search: the passage that matches, with the search's words in bold (FR-V-17).
            model.vault.query = "title at Chatham"
            await model.vault.load()
            await mainScene("vault-search") {
                model.vault.selection = model.vault.memories.first(where: { $0.title == "Role at Chatham" }).map { [$0.id] } ?? []
            }
            // Search answers (FR-AI-17): an answer quoting two memories that disagree, the first
            // number clicked (its quote highlighted in the detail), and no answer.
            model.vault.query = "title at Chatham"
            await model.vault.load()
            if let role = model.vault.memories.first(where: { $0.title == "Role at Chatham" }),
               let old = model.vault.memories.first(where: { $0.title == "Chatham job" }) {
                await mainScene("vault-answer") {
                    model.vault.reviewAnswer(SearchAnswer.review(role: role.id, old: old.id), results: model.vault.memories.count)
                    model.vault.showSource(role.id, quote: "my title at Chatham is now Senior Analyst")
                }
                await mainScene("vault-answer-none") {
                    model.vault.selection = []
                    model.vault.reviewAnswer(SearchAnswer(outcome: .noAnswer, claims: [], read: 3, withheld: 1, dropped: 0,
                                                          engine: "claude-code/haiku", locality: .cloud, duration: .seconds(4)),
                                             results: model.vault.memories.count)
                }
            }
            // Why lines (Phase 13b): with learned facts in use, a search for Maria finds the memory that only says
            // "my sister", with its why line; Ana, a friend, and a sister Funes can't tell apart from her show the others.
            let store = model.services.store
            let learned: [(String, String, String?, String, String)] = [
                ("Maria is my sister", "We grew up in Porto together.", "Maria", "sister", "Maria is my sister"),
                ("My sister drinks her mate bitter", "Every morning, with no sugar, from the gourd she brought back.", nil, "", ""),
                ("Ana and the climbing gym", "Ana is my friend from the climbing gym; she drinks matcha.", "Ana", "friend", "Ana is my friend"),
            ]
            for (title, body, person, word, quote) in learned where suffix == "light" {      // once: they're kept
                if let m = try? store.createMemory(MemoryDraft(title: title, body: body, kind: .fact, categoryKeys: ["personal_preferences"],
                                                               sensitivity: .low), now: Date().addingTimeInterval(-86_400)) {
                    try? store.reviewLearn(memoryID: m.id, person: person, word: word, quote: quote)
                }
            }
            model.searchFactsOverride = .review()
            model.applySearchFacts()
            model.vault.query = "Maria"
            await model.vault.load()
            await mainScene("vault-search-why") {
                model.vault.selection = model.vault.memories.first(where: { $0.title == "My sister drinks her mate bitter" }).map { [$0.id] } ?? []
            }
            // An answer with learned facts (Phase 13d): a claim code marked inferred, with its tag, and a result whose link
            // is above the cloud limit, not read.
            if let mate = model.vault.memories.first(where: { $0.title == "My sister drinks her mate bitter" }),
               let maria = model.vault.memories.first(where: { $0.title == "Maria is my sister" }) {
                await mainScene("vault-answer-inferred") {
                    model.vault.selection = []
                    model.vault.reviewAnswer(SearchAnswer.reviewInferred(mate: mate.id, maria: maria.id), results: model.vault.memories.count)
                }
            }
            model.searchFactsOverride = nil
            model.applySearchFacts()
            model.vault.query = ""
            await model.vault.load()
            await peopleScenes(model: model, suffix: suffix, main: main)
            // A tidy-up's automatic change in a memory's History, opened (FR-V-12).
            HistoryList.reviewExpandsChanges = true
            model.vault.status = .archived
            await model.vault.load()
            await mainScene("vault-memory-history") {
                model.vault.selection = model.vault.memories.first(where: { $0.title == "Dark mode" }).map { [$0.id] } ?? []
            }
            // An edit's earlier version in History (FR-V-16).
            model.vault.status = .active
            await model.vault.load()
            await mainScene("vault-memory-version") {
                model.vault.selection = model.vault.memories.first(where: { $0.title == "Coffee order" }).map { [$0.id] } ?? []
            }
            HistoryList.reviewExpandsChanges = false
            // Tidy Up on one memory (memory processing §9.7): its result under the actions.
            MemoryDetailView.reviewScrollsToActions = true
            await mainScene("vault-memory-tidy") {
                guard let memory = model.vault.memories.first(where: { $0.title == "Commit messages" }) else { return }
                model.tidyUp.reviewResult(.suggestions([UUID()]), for: memory)
                model.vault.selection = [memory.id]
            }
            MemoryDetailView.reviewScrollsToActions = false
            model.vault.status = .recentlyDeleted
            await model.vault.load()
            await mainScene("vault-recently-deleted") {
                model.vault.selection = model.vault.memories.first.map { [$0.id] } ?? []
            }
            model.vault.status = .active
            await model.vault.load()
            await mainScene("inbox") { model.section = .inbox }
            // Phase 6a: a capture still processing, one whose split failed, and Applied automatically below.
            model.inboxState.focused = model.inboxState.processing.keys.first
            try? await Task.sleep(for: .milliseconds(600))
            await snapshot("inbox-processing-\(suffix)", main.window)
            // Phase 6b: the Tidy-up section, with a merge, a conflict and its header.
            // The lazy list lays the far rows out on the way: scroll again once it has.
            let tidied = model.inbox.first(where: { $0.origin == .consolidation })?.id
            model.inboxState.focused = tidied
            try? await Task.sleep(for: .milliseconds(600))
            model.inboxState.focused = nil
            try? await Task.sleep(for: .milliseconds(100))
            model.inboxState.focused = tidied
            try? await Task.sleep(for: .milliseconds(900))
            await snapshot("inbox-tidy-up-\(suffix)", main.window)
            model.inboxState.focused = nil
            await mainScene("agents-access") {
                model.selectedAgentID = fixture.agents.claudeCode.id
                model.agentTab = .access
                model.section = .agents
            }
            await mainScene("agents-connect") {
                model.selectedAgentID = fixture.agents.cursor?.id
                model.agentTab = .connect
            }
            // A Claude Desktop agent in a window about as narrow as the user's, then Add to Claude
            // Desktop… through the Connect tab's own path: the sheet the user sees.
            main.window?.setContentSize(NSSize(width: 900, height: 680))
            await mainScene("agents-connect-claude-desktop") {
                model.selectedAgentID = fixture.claudeDesktop.id
                model.agentTab = .connect
            }
            model.agentTab = .access
            try? await Task.sleep(for: .milliseconds(300))
            ConnectTab.reviewStartsOneClick = .claudeDesktop
            model.agentTab = .connect
            for _ in 0..<40 where main.window?.attachedSheet == nil { try? await Task.sleep(for: .milliseconds(100)) }
            await snapshot("one-click-sheet-\(suffix)", main.window?.attachedSheet)
            model.agentTab = .access
            try? await Task.sleep(for: .milliseconds(500))
            main.window?.setContentSize(NSSize(width: 1_040, height: 680))
            await mainScene("activity") {
                model.section = .activity
                model.activity.selection = model.activity.entries.first(where: { $0.event.event == "request_memory" })?.id
            }
            // What a change did (FR-L-02): an automatic change, and a tidy-up run's list.
            await mainScene("activity-change") {
                model.activity.selection = model.activity.entries.first(where: { $0.event.event == "auto_applied" })?.id
            }
            await mainScene("activity-tidy-up") {
                model.activity.selection = model.activity.entries.first(where: { $0.event.event == "tidy_up_run" })?.id
            }
            // The facts rows' words (Phase 13): counts only, narrowed to the sample rows' span.
            await mainScene("activity-facts") {
                let facts = model.activity.entries.filter { FactsActivityWords.events.contains($0.event.event) }
                if let first = facts.last?.time, let last = facts.first?.time {
                    model.showActivity(.period(DateInterval(start: first, end: last.addingTimeInterval(60))))
                }
                model.activity.selection = facts.first(where: { $0.event.event == "facts_backfill" })?.id
            }
            model.activityFocus = nil

            // Remote Access: before setup, the guide, set up, and an agent's Cloud tab.
            let remote = model.remoteAccess
            await mainScene("remote-not-set-up") {
                remote.reviewSet(enabled: false, origin: nil, tunnel: nil)
                remote.guideActive = false
                model.section = .remoteAccess
            }
            await mainScene("remote-guide-1") { remote.guideActive = true }
            await mainScene("remote-set-up") {
                remote.guideActive = false
                remote.reviewSet(enabled: true, origin: "https://my-mac.tail1234.ts.net", tunnel: .tailscaleFunnel,
                                 test: .reachable(rtt: 0.18, tunnel: .tailscaleFunnel, at: Date()),
                                 health: .running(address: "https://my-mac.tail1234.ts.net", port: remote.port))
            }
            await mainScene("agents-cloud") {
                model.selectedAgentID = fixture.cloudAgent.id
                model.agentTab = .cloud
                model.section = .agents
            }

            // Every section at the window's minimum size (04-ux-mac.md), where nothing may run off
            // the right edge. Each is shown at the default size first and then shrunk, as a user
            // resizing the window would. Remote Access is set up, as above.
            func minScene(_ name: String, _ prepare: () -> Void) async {
                main.window?.setContentSize(NSSize(width: 1_040, height: 680))
                prepare()
                main.show()
                try? await Task.sleep(for: .milliseconds(300))
                main.window?.setContentSize(MainWindowController.minimumSize)
                await snapshot("\(name)-min-\(suffix)", main.window)
            }
            await minScene("home") { model.section = .home }
            await minScene("agents-cloud") {
                model.selectedAgentID = fixture.cloudAgent.id
                model.agentTab = .cloud
                model.section = .agents
            }
            await minScene("agents-access") {
                model.selectedAgentID = fixture.agents.claudeCode.id
                model.agentTab = .access
            }
            await minScene("agents-connect") {
                model.selectedAgentID = fixture.claudeDesktop.id
                model.agentTab = .connect
            }
            await minScene("remote") { model.section = .remoteAccess }
            await minScene("vault") {
                model.section = .vault
                model.vault.selection = model.vault.memories.first(where: { $0.title == "Commit messages" }).map { [$0.id] } ?? []
            }
            await minScene("inbox") { model.section = .inbox }
            await minScene("activity") {
                model.section = .activity
                model.activity.selection = model.activity.entries.first(where: { $0.event.event == "request_memory" })?.id
            }
            // The sidebar's status line, which shows only while something's off. Paused without
            // model.pause, which would add rows to the next pass's Activity.
            await minScene("sidebar-paused") {
                let until = Date().addingTimeInterval(3_600)
                model.services.pause.pause(until: until)
                model.pausedUntil = until
                model.section = .vault
            }
            model.services.pause.resume()
            model.pausedUntil = nil
            main.window?.setContentSize(NSSize(width: 1_040, height: 680))
            model.agentTab = .access

            let empty = MainWindowController(model: fixture.empty)
            keep.append(empty)
            // A new vault's Home: its empty states, without the checklist above them.
            fixture.empty.checklist.dismiss()
            fixture.empty.section = .home
            empty.show()
            await snapshot("home-empty-\(suffix)", empty.window)
            fixture.empty.section = .vault
            await snapshot("vault-empty-\(suffix)", empty.window)
            fixture.empty.section = .agents
            await snapshot("agents-empty-\(suffix)", empty.window)
            empty.close()

            // Sheets, as windows of their own.
            await sheet("new-memory-\(suffix)", NewMemorySheet(model: model) { _ in })
            await sheet("categories-\(suffix)", CategoriesSheet(model: model))
            await sheet("add-agent-\(suffix)", AddAgentSheet(model: model) { _ in })
            // An embedding model typed as an account's first model: the sheet explains it.
            await sheet("add-account-embedding-model-\(suffix)",
                        AddAccountSheet(model: model, account: AIAccount(endpoint: .lmStudio(), name: "LM Studio",
                                                                         models: ["qwen3-embedding:0.6b"])) { _ in })
            await sheet("add-agent-cloud-\(suffix)", AddAgentSheet(model: model, place: .cloud) { _ in })
            await sheet("seed-questions-name-\(suffix)", SeedQuestionsSheet(model: model))
            await sheet("seed-questions-\(suffix)", SeedQuestionsSheet(model: model, startsWithName: false))
            // The Access tab's About you card, below the fold in agents-access (ADR-0026).
            await sheet("access-about-you-\(suffix)", ProfileFieldsCard(model: model, agentName: fixture.agents.claudeCode.name,
                                                                         fields: .constant(fixture.agents.claudeCode.access.profileFields),
                                                                         reads: true)
                .frame(width: 640).padding(20))
            await sheet("import-claude-\(suffix)", ImportSheet(model: model, kind: .claude))
            if let preview = try? await withCheckedThrowingContinuation({ (done: CheckedContinuation<OneClickPreview, Error>) in
                model.setupControls.preview(.claudeDesktop, model.setupContext(for: fixture.agents.claudeCode)) { result in
                    done.resume(with: result)
                }
            }) {
                await sheet("one-click-preview-\(suffix)", ConfigPreviewSheet(preview: preview, agentName: "Claude Desktop") { _ in })
            }

            // Panels.
            await panel("share-panel-\(suffix)", fixture.shareItem)
            // A weaker match offered unticked under "Also matched" (access policy §3.2).
            var weak = fixture.shareItem
            if weak.rows.count > 1 {
                weak.rows[weak.rows.count - 1].weak = true
                weak.rows[weak.rows.count - 1].selected = false
            }
            await panel("share-panel-weak-\(suffix)", weak)
            await panel("save-panel-\(suffix)", saveItem(fixture))
            // A burst of suggestions: chips, "+3 more" and Later for all 6 suggestions.
            await panel("save-panel-burst-\(suffix)", saveItem(fixture), saveItem(fixture), saveItem(fixture),
                        saveItem(fixture), saveItem(fixture), saveItem(fixture))
            await panel("share-panel-remote-\(suffix)", fixture.remoteShareItem)
            await sheet("sign-in-panel-\(suffix)", SignInPanelView(model: model, request: PairingRequest(
                id: UUID(), clientID: fixture.cloudAgent.id.db, appName: "Claude", appURL: "https://claude.ai/oauth/claude-code-client-metadata",
                redirectHost: "claude.ai", code: "482 913", expiresAt: Date().addingTimeInterval(300))))
            let access = FunesApprovals.accessItem(
                AccessPrompt(agentID: fixture.agents.cursor?.id ?? UUID(), categoryKey: "project_context", operation: .read,
                             task: "Summarize the user's current projects", expiresAt: Date().addingTimeInterval(38.5)),
                agentName: "Cursor", categoryName: "Project context")
            await panel("access-panel-\(suffix)", access)
            // Three at once: the access request (on a clock) comes before the Save panel.
            await panel("panel-queue-\(suffix)", saveItem(fixture), access, fixture.shareItem)
            let box = CaptureBoxModel()
            box.text = "my OpenAI key is sk-proj-" + String(repeating: "x", count: 30)
            box.error = SecretText.message([.openAIStyleKey])
            await sheet("capture-box-\(suffix)", CaptureBox(box: box).padding(20), titled: false)
            let cloudBox = CaptureBoxModel()
            cloudBox.text = "Prefers morning meetings before 11"
            cloudBox.cloudProvider = "Anthropic"
            await sheet("capture-box-cloud-\(suffix)", CaptureBox(box: cloudBox).padding(20), titled: false)
            await sheet("capture-hud-\(suffix)", HUDView(text: String(localized: "Saved to Inbox"), symbol: "checkmark.circle.fill").padding(20),
                        titled: false)
            await sheet("menu-bar-icons-\(suffix)", MenuIconStrip().padding(16), titled: false)
            // The menu bar panel (Phase 10), state by state.
            await menuBarPanelScenes(fixture, saveItem: saveItem(fixture), suffix: suffix)

            // Settings, pane by pane and page by page (ADR-0030), then the problem scenes.
            let settings = SettingsWindowController(model: model)
            keep.append(settings)
            let ai = model.modelSettings
            func show(_ destination: SettingsDestination, _ name: String? = nil) async {
                model.goToSettings(destination)
                settings.show()
                try? await Task.sleep(for: .milliseconds(300))
                await snapshot("settings-\(name ?? destination.safeName)-\(suffix)", settings.window)
            }
            for pane in SettingsPane.allCases { await show(SettingsDestination(pane)) }
            for page in [SettingsPage.newMemories, .tidyUp, .searchAnswers, .facts, .searchIndex, .account("anthropic"),
                         .account("ollama"), .account("claude-code"), .account("codex")] {
                await show(SettingsDestination(page))
            }
            // A missing key: the jobs on Anthropic say so, and so does its page.
            try? ai.setKey(nil, for: "anthropic")
            await show(SettingsDestination(.features), "ai-features-no-key")
            await show(.account("anthropic"), "ai-accounts-anthropic-no-key")
            try? ai.setKey("review", for: "anthropic")
            // A plan paused after a tool event, and an uninstalled plan with usage from before.
            ai.reviewPlans([.claudeCode: "/usr/local/bin/claude"], [.claudeCode: .blocked, .codex: .notInstalled])
            ai.addUsage(ProviderUsage(requests: 3, inputTokens: 9_800, outputTokens: 610), for: "codex")
            await show(SettingsDestination(.features), "ai-features-blocked-plan")
            await show(.account("claude-code"), "ai-accounts-claude-code-blocked")
            await show(.account("codex"), "ai-accounts-codex-usage")
            ai.resetUsage(for: "codex")
            ai.reviewPlans([.claudeCode: "/usr/local/bin/claude"], [.claudeCode: .ready(version: "2.1.310"), .codex: .notInstalled])
            // An account with no models, and a job's choice of it that has no model yet (unresolved).
            ai.upsert(AIAccount(endpoint: .lmStudio(), name: "LM Studio"))
            let answers = ai.choice(.searchAnswers)
            ai.setChoice(.model(ModelChoice(account: "lmstudio", model: nil)), for: .searchAnswers)
            await show(SettingsDestination(.features), "ai-features-unresolved")
            await show(.searchAnswers, "ai-features-search-answers-unresolved")
            await show(.account("lmstudio"), "ai-accounts-no-models")
            await show(SettingsDestination(.accounts), "ai-accounts-local-servers")
            ai.setChoice(answers, for: .searchAnswers)
            ai.removeAccount("lmstudio")
            // A second index (task 6c.3), starting its first pass.
            ai.setEmbedding(EmbeddingChoice(provider: "ollama", model: "qwen3-embedding:0.6b"))
            try? await Task.sleep(for: .seconds(1))
            await show(.searchIndex, "ai-features-search-index-second-index")
            await show(SettingsDestination(.privacy), "ai-privacy-second-index")
            ai.setEmbedding(nil)
            // Facts with more models recommended: review-only records, never measured and never shipped (the app uses the
            // bundled file). This build starts no runner.
            ai.factsQualification = Self.reviewFactsQualification()
            await show(.facts, "ai-features-facts-qualified")
            ai.factsLearn = true
            ai.factsUse = true
            await show(.facts, "ai-features-facts-learning")
            await show(SettingsDestination(.features), "ai-features-with-facts")
            await show(SettingsDestination(.privacy), "ai-privacy-facts")
            // The first backfill (FR-F-03): its sheet with a sample count, then its progress, paused, paused by a change,
            // and a wait for tomorrow's cap. Sample states only: this build reads no vault for them.
            let groups = FactsRegistry.bundled.callGroups.keys.sorted()
            await sheet("facts-backfill-sheet-\(suffix)", FactsBackfillSheet(
                model: model, mode: .start,
                preset: FactsBackfill.Estimate(memories: 407, calls: 730, kept: 42, groups: groups, limit: .upTo(.internal), cost: 0.22),
                shown: .constant(true)))
            var running = FactsBackfill.State(startedAt: Date(), memories: 365, calls: 730, engines: [:], limit: .upTo(.internal))
            model.factsBackfill = FactsBackfill.Progress(state: running, done: 120)
            await show(.facts, "ai-features-facts-backfill")
            await show(SettingsDestination(.features), "ai-features-with-facts-backfill")
            running.paused = true
            model.factsBackfill = FactsBackfill.Progress(state: running, done: 120)
            await show(.facts, "ai-features-facts-backfill-paused")
            running.paused = false
            running.changed = true
            model.factsBackfill = FactsBackfill.Progress(state: running, done: 120)
            await show(.facts, "ai-features-facts-backfill-changed")
            running.changed = false
            running.finishedAt = Date()
            running.ended = "done"
            model.factsBackfill = FactsBackfill.Progress(state: running, done: 365)
            model.factsCapWait = [.total]
            await show(.facts, "ai-features-facts-cap")
            model.factsCapWait = [.lowPriority]
            await show(.facts, "ai-features-facts-cap-share")
            model.factsCapWait = []
            model.factsBackfill = nil
            // A model Funes didn't test for every group: it runs everything, with the page's quiet line.
            ai.setFactsChoice(ModelChoice(account: "claude-code", model: "opus"))
            await show(.facts, "ai-features-facts-opus")
            ai.setFactsChoice(nil)
            ai.factsLearn = false
            ai.factsUse = false
            ai.factsQualification = .bundled
            settings.close()
        }
        main.close()
    }

    private func saveItem(_ fixture: Fixture) -> PanelItem {
        let suggestion = fixture.model.inbox.first { $0.origin == .agent && $0.targetMemoryID == nil }
        return PanelItem(
            id: UUID(), kind: .save, agentID: "", title: String(localized: "Save this memory?"),
            shortLabel: "Claude Code · save",
            subtitle: String(localized: "From Claude Code. It's in your Inbox either way."),
            agentSays: [PanelItem.Fact(label: String(localized: "Why"), value: suggestion?.evidence ?? "", collapsible: true)],
            rows: [PanelItem.Row(id: "s", title: suggestion?.title ?? "Prefers Vitest over Jest",
                                 detail: suggestion?.body ?? "", selectable: false)],
            facts: [PanelItem.Fact(label: String(localized: "Kind"), value: MemoryKind.preference.title),
                    PanelItem.Fact(label: String(localized: "Category"), value: "Software development"),
                    PanelItem.Fact(label: String(localized: "Sensitivity"), value: Sensitivity.low.title)],
            primary: String(localized: "Save"), secondary: String(localized: "Later"), tertiary: String(localized: "Discard"),
            edit: String(localized: "Edit…"), announcement: "")
    }

    // MARK: Showing and capturing

    private func sheet<Content: View>(_ name: String, _ view: Content, titled: Bool = true) async {
        let host = NSHostingController(rootView: view.environment(\.colorScheme, NSApp.effectiveAppearance.isDark ? .dark : .light))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = titled ? [.titled, .fullSizeContentView] : [.borderless]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = titled
        window.backgroundColor = titled ? .windowBackgroundColor : .clear
        window.center()
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        await snapshot(name, window)
        window.orderOut(nil)
    }

    private func panel(_ name: String, _ items: PanelItem...) async {
        let queue = ApprovalQueue()
        for item in items {
            var item = item
            // Countdowns start now, so a later pass doesn't find them expired. In a queue, the access
            // request is the one about to run out.
            if item.expiresAt != nil { item.expiresAt = Date().addingTimeInterval(item.kind == .access && items.count > 1 ? 13.5 : 41.5) }
            queue.enqueue(item) { _ in }
        }
        keep.append(queue)
        let height = ApprovalPanelController.idealHeight(for: queue)
        let host = NSHostingController(rootView: ApprovalPanelView(queue: queue, scrolls: false))
        host.sizingOptions = []
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: ApprovalPanelController.width, height: height),
                             styleMask: [.titled, .fullSizeContentView, .utilityWindow], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentViewController = host
        window.setContentSize(NSSize(width: ApprovalPanelController.width, height: height))
        window.center()
        windows.append(window)
        window.orderFrontRegardless()
        // The buttons arm after 0.6 s.
        try? await Task.sleep(for: .milliseconds(800))
        await snapshot(name, window)
        window.orderOut(nil)
    }

    /// Lets the window settle, then hands it to the script and waits until it's captured.
    private func snapshot(_ name: String, _ window: NSWindow?) async {
        guard let window else { return }
        // FUNES_UI_ONLY=<part of a name> captures only the matching scenes (ui_snapshots.sh passes it on).
        if let only = ProcessInfo.processInfo.environment["FUNES_UI_ONLY"], !only.isEmpty, !name.contains(only) { return }
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(900))
        window.displayIfNeeded()
        emit(["ready": name, "windowNumber": window.windowNumber])
        _ = await Task.detached { readLine() }.value
        files.append(name + ".png")
    }

    private func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: scratch)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        UserDefaults.standard.removePersistentDomain(forName: suiteName + "-empty")
    }
}

/// The four menu bar icon states, labelled.
private struct MenuIconStrip: View {
    var body: some View {
        HStack(spacing: 24) {
            ForEach(MenuBarIcon.State.allCases, id: \.self) { state in
                VStack(spacing: 6) {
                    Image(nsImage: MenuBarIcon.image(state)).renderingMode(state == .needsYou ? .original : .template)
                        .foregroundStyle(.primary)
                    Text(state.rawValue).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach([MenuBarIcon.State.normal, .needsYou], id: \.self) { state in
                VStack(spacing: 6) {
                    Image(nsImage: MenuBarIcon.image(state, remote: true)).renderingMode(state == .needsYou ? .original : .template)
                        .foregroundStyle(.primary)
                    Text(state.rawValue + " + remote").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
extension UIReview {
    /// The first scroll view under `view`, depth first.
    static func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }
}

extension UIReview {
    /// The menu bar panel's states (ADR-0029, 04-ux-mac.md ▸ Menu bar), each from the app's own
    /// state as the user would reach it: a Pending request waiting (the fixture's), a live access
    /// panel, a pause, a search with an answer, the port in use, Remote Access's tunnel down and its
    /// automatic turn-off, a new vault, and the most the panel holds.
    private func menuBarPanelScenes(_ fixture: Fixture, saveItem: PanelItem, suffix: String) async {
        let model = fixture.model
        let panelModel = MenuBarPanelModel(app: model, saver: CaptureSaver(model: model, hud: HUD()))
        let controller = MenuBarPanelController(model: panelModel)
        keep.append(controller)
        let pulse = Self.samplePulse(fixture)
        let field = panelModel.field
        let address = "https://my-mac.tail1234.ts.net"
        // Remote Access set up and off, whatever the window's scenes left.
        model.remoteAccess.reviewSet(enabled: false, origin: address, tunnel: .tailscaleFunnel)
        field.autoAskPause = { _ in nil }
        func scene(_ name: String, _ controller: MenuBarPanelController, pulse: RecentPulse?) async {
            let window = controller.reviewShow()
            if let pulse { controller.model.reviewPulse(pulse) }
            try? await Task.sleep(for: .milliseconds(600))
            await snapshot("\(name)-\(suffix)", window)
            controller.reviewHide()
        }
        /// A search of the sample vault, answered with the review's answer.
        func searchAndAnswer(_ text: String) async {
            field.text = text
            field.commandReturn()
            for _ in 0..<100 where field.page == nil { try? await Task.sleep(for: .milliseconds(20)) }
            let rows = field.page?.rows ?? []
            if let role = rows.first(where: { $0.title == "Role at Chatham" }), let old = rows.first(where: { $0.title == "Chatham job" }) {
                field.ask = { _, ids in
                    PanelSearchAnswer(answer: .review(role: role.id, old: old.id), results: field.page?.total ?? ids.count,
                                      engine: "Claude (Claude Code)", limit: Sensitivity.internal.title)
                }
                field.askNow()
                for _ in 0..<100 where field.answer.map({ if case .answered = $0 { false } else { true } }) ?? true {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        }
        let queue = model.services.approvals.queue
        func access(_ seconds: TimeInterval) -> PanelItem {
            FunesApprovals.accessItem(
                AccessPrompt(agentID: fixture.agents.cursor?.id ?? UUID(), categoryKey: "project_context", operation: .read,
                             task: "Summarize the user's current projects", expiresAt: Date().addingTimeInterval(seconds)),
                agentName: "Cursor", categoryName: "Project context")
        }

        // On, with the fixture's Pending request waiting.
        await scene("menubar-panel", controller, pulse: pulse)

        // Two cards: a live access panel (on a clock, with the Review Request shortcut) and the Pending request.
        let live = access(41.5)
        queue.enqueue(live) { _ in }
        await scene("menubar-panel-waiting", controller, pulse: pulse)
        queue.withdraw(live.id)

        model.pause(.oneHour)
        await scene("menubar-panel-paused", controller, pulse: pulse)
        model.resume()

        // Results and an answer, in place of the chart.
        await searchAndAnswer("title at Chatham")
        await scene("menubar-panel-search", controller, pulse: nil)

        model.mcpStatus = .failed(.portInUse(47_625))
        await scene("menubar-panel-cant-connect", controller, pulse: pulse)
        model.mcpStatus = .listening(port: 47_625)

        model.remoteAccess.reviewSet(enabled: true, origin: address, tunnel: .tailscaleFunnel, health: .notRunning(reason: .noTunnel))
        await scene("menubar-panel-remote-down", controller, pulse: pulse)
        model.remoteAccess.reviewSet(enabled: true, origin: address, tunnel: .tailscaleFunnel,
                                     health: .running(address: address, port: 443))
        model.remoteAccess.setAutoOff(4 * 3_600)
        await scene("menubar-panel-remote-until", controller, pulse: pulse)
        model.remoteAccess.setAutoOff(0)
        model.remoteAccess.reviewSet(enabled: false, origin: address, tunnel: .tailscaleFunnel)

        // A new vault with no agents.
        let empty = MenuBarPanelController(model: MenuBarPanelModel(app: fixture.empty,
                                                                    saver: CaptureSaver(model: fixture.empty, hud: HUD())))
        keep.append(empty)
        await scene("menubar-panel-empty", empty, pulse: nil)

        // The most it holds: 3 cards and the overflow, a 4-line field, an answer and 5 results.
        let fullAccess = access(13.5)
        var second = saveItem, third = saveItem
        second.cardTitle = "Claude Code wants to save a memory"
        third = PanelItem(id: UUID(), kind: third.kind, agentID: third.agentID, title: third.title, rows: third.rows,
                          primary: third.primary, secondary: third.secondary, announcement: "")
        third.cardTitle = "Codex wants to save a correction"
        for item in [fullAccess, second, third] { queue.enqueue(item) { _ in } }
        let search = field.search
        field.search = { _ in try await search("title at Chatham") }
        await searchAndAnswer("What's my title at Chatham now?\nAnd since when?\nWho was I before that?\nAnything older?")
        await scene("menubar-panel-full", controller, pulse: nil)
        field.search = search
        for item in [fullAccess, second, third] { queue.withdraw(item.id) }
    }

    /// A day of the sample vault's traffic: captures through the day, agents reading in the
    /// morning and afternoon, one refusal.
    private static func samplePulse(_ fixture: Fixture) -> RecentPulse {
        let now = Date()
        let current = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        let claude = fixture.agents.claudeCode.id.db, cursor = fixture.agents.cursor?.id.db ?? "cursor"
        let inbound: [Int: VaultOverview.Sources] = [1: .init(mac: 1), 3: .init(iphone: 2), 9: .init(mac: 1, agent: 1),
                                                    10: .init(mac: 3), 14: .init(iphone: 1), 18: .init(mac: 2),
                                                    20: .init(agent: 1), 22: .init(mac: 1), 23: .init(iphone: 1)]
        let out: [Int: [String: Int]] = [2: [claude: 2], 9: [claude: 4, cursor: 1], 10: [claude: 6], 11: [cursor: 2],
                                        15: [claude: 3], 16: [claude: 5, cursor: 2], 19: [claude: 1], 22: [cursor: 3]]
        let hours = (0..<24).map { i in
            VaultOverview.Bucket(date: current.addingTimeInterval(Double(i - 23) * 3_600), inbound: inbound[i] ?? .init(),
                                 out: out[i] ?? [:], refused: i == 16 ? 1 : 0)
        }
        return RecentPulse(generatedAt: now, timeZone: TimeZone.current.identifier, hours: hours,
                           agentNames: [claude: "Claude Code", cursor: "Cursor"])
    }
}

extension SearchAnswer {
    /// The review's answer: the newer title and the older one, each quoted (sample data's
    /// "Role at Chatham" and "Chatham job").
    /// "Maria drinks her mate bitter", inferred from "my sister" (the only sister Funes knows), and a claim its quote states.
    static func reviewInferred(mate: UUID, maria: UUID) -> SearchAnswer {
        let line = WhyLine(form: .name(name: "Maria", attribute: "your sister"), basis: .link(.soleKnown), label: "sister",
                           untrusted: false, notName: .init(memoryID: mate, entity: "e", name: "Maria"), notThis: "f")
        let corrections = [
            FactsCorrection(target: FactsCorrectionTarget(what: .name, linkID: "\(mate)/e", memoryID: mate, token: "t"), name: "Maria",
                            attribute: "your sister"),
            FactsCorrection(target: FactsCorrectionTarget(what: .fact, factID: "f", token: "t"), name: "Maria", attribute: "your sister"),
        ]
        var answer = SearchAnswer(outcome: .answered, claims: [
            Claim(text: "Maria drinks her mate bitter, every morning with no sugar.",
                  citations: [Citation(memoryID: mate, quote: "Every morning, with no sugar")],
                  inference: ClaimInference(basis: "sole_known", factIDs: ["f"], why: line, corrections: corrections)),
            Claim(text: "Maria is your sister; you grew up in Porto together.",
                  citations: [Citation(memoryID: maria, quote: "We grew up in Porto together.")]),
        ], read: 3, withheld: 0, dropped: 0, engine: "claude-code/haiku", locality: .cloud, duration: .seconds(5))
        answer.unreadLinked = 1
        answer.factsRevision = "review"
        return answer
    }

    static func review(role: UUID, old: UUID) -> SearchAnswer {
        SearchAnswer(outcome: .answered, claims: [
            Claim(text: "Your title at Chatham is Senior Analyst, since a promotion in March 2026.",
                  citations: [Citation(memoryID: role, quote: "my title at Chatham is now Senior Analyst")]),
            Claim(text: "An older note says you were a data analyst at Chatham Analytics.",
                  citations: [Citation(memoryID: old, quote: "Data analyst at Chatham Analytics")]),
        ], read: 3, withheld: 0, dropped: 1, engine: "claude-code/haiku", locality: .cloud, duration: .seconds(5))
    }
}
extension UIReview {
    /// The Facts page's qualified scenes only: Claude Haiku 5.5 for every call group through the Claude plan and an
    /// Anthropic key, and Claude Opus 5.5 for the people group through the plan. Made up for the review build; not
    /// evidence of anything, and never in `Resources/facts-qualification.json`.
    // MARK: People & history (Phase 13c)

    /// Activity's facts rows, yesterday (sample counts, never the real vault): a backfill's start and end, a learned run,
    /// corrections from the Mac and a paired iPhone, an Undo, and Remove Learned Facts.
    private static func recordFactsActivity(_ activity: any ActivityRecorder) {
        let day = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-14 * 3_600)
        func row(_ minutes: Double, _ actor: Actor, via: ActivityEvent.Via = .app, _ event: String, outcome: String? = nil,
                 ids: [UUID] = [], counts: [String: Int], engine: String? = nil) {
            activity.record(ActivityEvent(time: day.addingTimeInterval(minutes * 60), phase: .event, actor: actor, via: via,
                                          event: event, outcome: outcome, ids: ids, counts: counts, engine: engine))
        }
        row(0, .user, "facts_backfill", outcome: "started", counts: ["memories": 365, "calls": 730])
        row(95, .system, "facts_backfill", outcome: "finished", counts: ["memories": 365, "calls": 720, "code_only": 10, "failed": 0])
        row(120, .system, "facts_learned", ids: [UUID()], counts: ["memories": 3, "calls": 2, "applied": 2, "code_only": 1, "failed": 0],
            engine: "anthropic/\(AnthropicClient.suggestedModel)")
        row(125, .system, "facts_learned", ids: [UUID()], counts: ["memories": 2, "calls": 2, "applied": 1, "failed": 1],
            engine: "anthropic/\(AnthropicClient.suggestedModel)")
        row(130, .user, "facts_corrected", counts: ["entities": 1, "facts": 1])
        row(140, .device(UUID()), via: .companion, "facts_corrected", counts: ["links": 1])
        row(150, .user, "facts_corrected", counts: ["undone": 2])
        row(200, .user, "facts_removed", counts: ["entities": 23, "facts": 41, "evidence": 120, "decisions": 7])
    }

    /// People & history with sample facts (never the real vault): the list, Maria's page, your timeline, To check, the
    /// timeline as it ships (unqualified), and the empty state with Facts off.
    private func peopleScenes(model: AppModel, suffix: String, main: MainWindowController) async {
        func scene(_ name: String, _ prepare: () -> Void) async {
            prepare()
            main.show()
            await snapshot("\(name)-\(suffix)", main.window)
        }
        let store = model.services.store
        let ai = model.modelSettings
        // Facts off, nothing of yours: the empty state.
        model.peopleConfigOverride = .review()
        await model.refresh()
        // The light pass's seed leaves entries of yours; the empty state is what you'd see with none.
        model.hasUserFactEntries = false
        await scene("people-empty-off") { model.section = .people }
        if suffix == "light" { Self.seedPeople(store: store) }
        ai.factsQualification = Self.reviewFactsQualification()
        ai.factsLearn = true
        await model.refresh()
        let people = model.people
        people.tab = .people
        people.selection = nil
        await people.load()
        await scene("people-list") { model.section = .people }
        people.selection = people.directory?.entries.first { $0.name == "Maria" }?.id
        await people.load()
        await scene("people-entity") {}
        people.tab = .timeline
        await scene("people-timeline") {}
        people.tab = .toCheck
        await scene("people-to-check") {}
        model.peopleConfigOverride = .reviewShipped()
        people.tab = .timeline
        await people.load()
        await scene("people-timeline-off") {}
        model.peopleConfigOverride = nil
        people.clear()
        people.tab = .people
        ai.factsLearn = false
        ai.factsQualification = .bundled
        await model.refresh()
    }

    /// Sample people, organizations and jobs: Maria and Elena (sisters, so a later "my sister" is unsettled), Maria
    /// Lopez (a merge suggestion), Ana, your parents, Globex (a client, recorded only), and a work history with a title
    /// change, a conflicting start, an undated job and a date of yours whose episode split.
    private static func seedPeople(store: VaultStore) {
        let reg = FactsRegistry.bundled
        func pred(_ word: String) -> FactsRegistry.Predicate? { reg.predicates.first { p in p.lexicon.contains { $0.words.contains(word) } } }
        guard let sib = pred("sister"), let colleague = pred("colleague") ?? pred("coworker"), let parent = pred("parents"),
              let client = reg.predicates.first(where: { $0.uses == ["recorded"] }),
              let work = reg.predicates.first(where: { $0.uses.contains("timeline") }) else { return }
        let slot = work.slot ?? "kind"
        let employee = work.qualifiers[slot]?.values?.first ?? "employee"
        let day: Double = 86_400
        func memory(_ title: String, _ body: String, daysAgo: Double) -> UUID? {
            try? store.createMemory(MemoryDraft(title: title, body: body, kind: .fact, categoryKeys: ["personal_preferences"],
                                                sensitivity: .low), now: Date().addingTimeInterval(-daysAgo * day)).id
        }
        func apply(_ id: UUID?, _ x: FactsExtraction, _ group: String, daysAgo: Double) {
            guard let id else { return }
            try? store.reviewApply(memoryID: id, extraction: x, callGroup: group, now: Date().addingTimeInterval(-daysAgo * day))
        }
        func person(_ name: String, _ p: FactsRegistry.Predicate, _ label: String?, _ quote: String) -> FactsExtraction {
            FactsExtraction(people: [ExtractedPerson(name: name, quote: quote)],
                            facts: [ExtractedFact(predicate: p.id, name: name, label: label, quote: quote)])
        }
        func job(_ name: String, _ start: String?, _ end: String?, title: String?, _ quote: String) -> FactsExtraction {
            var q = [slot: employee]
            if let title { q["title"] = title }
            return FactsExtraction(facts: [ExtractedFact(predicate: work.id, name: name, quote: quote, start: start, end: end, qualifiers: q)])
        }
        apply(memory("Elena is my sister too", "Elena moved to Lyon last spring.", daysAgo: 6),
              person("Elena", sib, "sister", "Elena is my sister"), sib.callGroup, daysAgo: 6)
        apply(memory("Call my sister", "About the trip to Porto in May.", daysAgo: 2), FactsExtraction(), sib.callGroup, daysAgo: 2)
        apply(memory("Maria Lopez on the design review", "Maria Lopez is my colleague on the platform team.", daysAgo: 9),
              person("Maria Lopez", colleague, "colleague", "Maria Lopez is my colleague"), sib.callGroup, daysAgo: 9)
        apply(memory("Sunday lunch", "My parents are cooking paella this Sunday.", daysAgo: 4),
              FactsExtraction(facts: [ExtractedFact(predicate: parent.id, name: "", entity: "group", label: "parents", quote: "My parents", count: 2)]),
              parent.callGroup, daysAgo: 4)
        apply(memory("Globex renewal", "Globex is our client; the renewal is due in March.", daysAgo: 12),
              FactsExtraction(facts: [ExtractedFact(predicate: client.id, name: "Globex", quote: "Globex is our client")]), client.callGroup, daysAgo: 12)
        apply(memory("First job", "I joined Acme as an engineer in 2015 and left in 2017.", daysAgo: 40),
              job("Acme", "2015", "2017", title: "Engineer", "I joined Acme as an engineer in 2015"), work.callGroup, daysAgo: 40)
        apply(memory("Promotion at Acme", "In 2016 I became a senior engineer at Acme.", daysAgo: 39),
              job("Acme", "2016", nil, title: "Senior engineer", "In 2016 I became a senior engineer at Acme"), work.callGroup, daysAgo: 39)
        apply(memory("Initech", "I started at Initech in 2017 and stayed until 2021.", daysAgo: 30),
              job("Initech", "2017", "2021", title: nil, "I started at Initech in 2017"), work.callGroup, daysAgo: 30)
        apply(memory("Initech start", "My first day at Initech was in 2018.", daysAgo: 29),
              job("Initech", "2018", nil, title: nil, "My first day at Initech was in 2018"), work.callGroup, daysAgo: 29)
        apply(memory("Back at Acme", "I rejoined Acme in 2021 as a staff engineer.", daysAgo: 10),
              job("Acme", "2021", nil, title: "Staff engineer", "I rejoined Acme in 2021"), work.callGroup, daysAgo: 10)
        apply(memory("Hooli contract", "I did a contract at Hooli at some point.", daysAgo: 8),
              job("Hooli", nil, nil, title: nil, "I did a contract at Hooli"), work.callGroup, daysAgo: 8)
        // A job of yours: it shows on the timeline even while the timeline is unqualified.
        _ = try? store.addManualEntry(PeopleManualEntry(kind: work.objectKind, name: "Freelance studio", predicate: work.id,
                                                        start: "2012-09", end: "2014", status: .former),
                                      activity: InMemoryActivityLog(), now: Date().addingTimeInterval(-3 * day))
        // A status of yours set on "Acme" before its two stints were known apart: To check asks which one.
        let config = FactsSearchConfig.review()
        if let d = try? store.peopleDirectory(config: config), let acme = d.entries.first(where: { $0.name == "Acme" }),
           let fid = try? store.peopleEntity(acme.id, config: config)?.facts.first?.factID,
           let lo = DayNumber.from(year: 2015, month: 1, day: 1), let hi = DayNumber.from(year: 2022, month: 12, day: 31) {
            try? store.setFactStatus(fid, .current, selector: DateRange(lo: lo, hi: hi), activity: InMemoryActivityLog())
        }
    }

    static func reviewFactsQualification() -> FactsQualification {
        let registry = FactsRegistry.bundled, versions = FactsQualification.promptVersions(registry)
        func record(_ group: String, _ engine: FactsEngine) -> FactsQualification.Record {
            let predicates = registry.predicates.filter { $0.callGroup == group }
            return FactsQualification.Record(predicates: predicates.map(\.id), uses: ["recorded"], callGroup: group, engine: engine,
                                             promptVersion: versions[group] ?? "", registryVersion: registry.fingerprint,
                                             gate: "UI review only", recordedAt: "2026-11-18")
        }
        let plan = { (model: String) in
            FactsEngine(ClaudeCodeClient(executable: "/usr/bin/false", model: model))
        }
        let key = FactsEngine(model: "anthropic/\(FactsClients.defaultModel)", adapter: "anthropic")
        var records: [FactsQualification.Record] = []
        for group in registry.callGroups.keys.sorted() {
            records.append(record(group, plan(FactsClients.defaultModel)))
            records.append(record(group, key))
        }
        return FactsQualification(reviewRecords: records)
    }
}

#endif
