#if FUNES_UI_REVIEW
import AppKit
import BridgeKitCore
import BridgeKitRemote
import BridgeUI
import FunesCore
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
            model.vault.query = ""
            await model.vault.load()
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
            for page in [SettingsPage.newMemories, .tidyUp, .searchAnswers, .searchIndex, .account("anthropic"),
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
            // A second index (task 6c.3): with no Ollama running, its status says so.
            ai.setEmbedding(EmbeddingChoice(provider: "ollama", model: "qwen3-embedding:0.6b"))
            try? await Task.sleep(for: .seconds(1))
            await show(.searchIndex, "ai-features-search-index-error")
            await show(SettingsDestination(.privacy), "ai-privacy-second-index")
            ai.setEmbedding(nil)
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

extension SearchAnswer {
    /// The review's answer: the newer title and the older one, each quoted (sample data's
    /// "Role at Chatham" and "Chatham job").
    static func review(role: UUID, old: UUID) -> SearchAnswer {
        SearchAnswer(outcome: .answered, claims: [
            Claim(text: "Your title at Chatham is Senior Analyst, since a promotion in March 2026.",
                  citations: [Citation(memoryID: role, quote: "my title at Chatham is now Senior Analyst")]),
            Claim(text: "An older note says you were a data analyst at Chatham Analytics.",
                  citations: [Citation(memoryID: old, quote: "Data analyst at Chatham Analytics")]),
        ], read: 3, withheld: 0, dropped: 1, engine: "claude-code/haiku", locality: .cloud, duration: .seconds(5))
    }
}
#endif
