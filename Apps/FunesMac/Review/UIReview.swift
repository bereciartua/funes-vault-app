#if FUNES_UI_REVIEW
import AppKit
import BridgeKitCore
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
        let shareItem: PanelItem
    }

    private func makeFixture() async throws -> Fixture {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let defaults = UserDefaults(suiteName: suiteName)!
        let preferences = Preferences(defaults: defaults)
        let environment = try VaultEnvironment(dataFolder: scratch.appendingPathComponent("vault"))
        let agents = try await SampleData.fill(environment)
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
        let settings = ModelSettings(defaults: defaults, keys: InMemoryProviderKeyStore())
        try settings.upsert(ProviderConfig(endpoint: .ollama(), name: "Ollama", model: "llama3.2"), key: nil)
        try settings.upsert(ProviderConfig(endpoint: .anthropic(), name: "Anthropic", model: AnthropicClient.suggestedModel), key: "review")
        settings.setClassifier("anthropic")
        let model = AppModel(services: environment, preferences: preferences, modelSettings: settings)
        configure(model)
        await model.refresh()
        await model.activity.load()

        let panel = try await environment.disclosures.panel(requestID: waiting.requestID!, now: Date())!
        let disclosure = try await environment.disclosures.disclosure(requestID: waiting.requestID!)
        var share = FunesApprovals.shareItem(panel, withheld: disclosure?.withheld ?? [:], now: Date())
        share.expiresAt = Date().addingTimeInterval(41.5)

        let emptyDefaults = UserDefaults(suiteName: suiteName + "-empty")!
        let emptyEnvironment = try VaultEnvironment(dataFolder: scratch.appendingPathComponent("empty"), embeddings: false)
        let empty = AppModel(services: emptyEnvironment, preferences: Preferences(defaults: emptyDefaults),
                             modelSettings: ModelSettings(defaults: emptyDefaults, keys: InMemoryProviderKeyStore()))
        configure(empty)
        await empty.refresh()
        return Fixture(model: model, empty: empty, agents: agents, shareItem: share)
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
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)

            // The main window, section by section.
            func mainScene(_ name: String, _ prepare: () -> Void) async {
                prepare()
                main.show()
                await snapshot("\(name)-\(suffix)", main.window)
            }
            await mainScene("vault-checklist") {
                model.checklist.reset(model: model)
                model.section = .vault
                model.vault.status = .active
                model.vault.selection = []
            }
            await mainScene("vault-memory") {
                model.checklist.dismiss()
                model.vault.selection = model.vault.memories.first(where: { $0.title == "Commit messages" }).map { [$0.id] } ?? []
            }
            model.vault.status = .recentlyDeleted
            await model.vault.load()
            await mainScene("vault-recently-deleted") {
                model.vault.selection = model.vault.memories.first.map { [$0.id] } ?? []
            }
            model.vault.status = .active
            await model.vault.load()
            await mainScene("inbox") { model.section = .inbox }
            await mainScene("agents-access") {
                model.selectedAgentID = fixture.agents.claudeCode.id
                model.agentTab = .access
                model.section = .agents
            }
            await mainScene("agents-connect") {
                model.selectedAgentID = fixture.agents.cursor?.id
                model.agentTab = .connect
            }
            await mainScene("activity") {
                model.section = .activity
                model.activity.selection = model.activity.entries.first(where: { $0.event.event == "request_memory" })?.id
            }

            let empty = MainWindowController(model: fixture.empty)
            keep.append(empty)
            fixture.empty.section = .vault
            empty.show()
            await snapshot("vault-empty-\(suffix)", empty.window)
            empty.close()

            // Sheets, as windows of their own.
            await sheet("new-memory-\(suffix)", NewMemorySheet(model: model) { _ in })
            await sheet("categories-\(suffix)", CategoriesSheet(model: model))
            await sheet("add-agent-\(suffix)", AddAgentSheet(model: model) { _ in })
            await sheet("seed-questions-\(suffix)", SeedQuestionsSheet(model: model))
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
            await panel("save-panel-\(suffix)", saveItem(fixture))
            await panel("access-panel-\(suffix)", FunesApprovals.accessItem(
                AccessPrompt(agentID: fixture.agents.cursor?.id ?? UUID(), categoryKey: "project_context", operation: .read,
                             task: "Summarize the user's current projects", expiresAt: Date().addingTimeInterval(38.5)),
                agentName: "Cursor", categoryName: "Project context"))
            let box = CaptureBoxModel()
            box.text = "my OpenAI key is sk-proj-" + String(repeating: "x", count: 30)
            box.error = SecretText.message([.openAIStyleKey])
            await sheet("capture-box-\(suffix)", CaptureBox(box: box).padding(20), titled: false)
            await sheet("capture-hud-\(suffix)", HUDView(text: String(localized: "Saved to Inbox"), symbol: "checkmark.circle.fill").padding(20),
                        titled: false)
            await sheet("menu-bar-icons-\(suffix)", MenuIconStrip().padding(16), titled: false)

            // Settings, tab by tab.
            let settings = SettingsWindowController(model: model)
            keep.append(settings)
            for tab in SettingsTab.allCases {
                model.settingsTab = tab
                settings.show()
                await snapshot("settings-\(tab.rawValue)-\(suffix)", settings.window)
            }
            settings.close()
        }
        main.close()
    }

    private func saveItem(_ fixture: Fixture) -> PanelItem {
        let suggestion = fixture.model.inbox.first { $0.origin == .agent && $0.targetMemoryID == nil }
        return PanelItem(
            id: UUID(), kind: .save, agentID: "", title: String(localized: "Save this memory?"),
            subtitle: String(localized: "From Claude Code. It's in your Inbox either way."),
            rows: [PanelItem.Row(id: "s", title: suggestion?.title ?? "Prefers Vitest over Jest",
                                 detail: suggestion?.body ?? "", selectable: false)],
            facts: [PanelItem.Fact(label: String(localized: "Kind"), value: MemoryKind.preference.title),
                    PanelItem.Fact(label: String(localized: "Category"), value: "Software development"),
                    PanelItem.Fact(label: String(localized: "Sensitivity"), value: Sensitivity.low.title),
                    PanelItem.Fact(label: String(localized: "Why"),
                                   value: "“\(suggestion?.evidence ?? "")” (as reported)", collapsible: true)],
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

    private func panel(_ name: String, _ item: PanelItem) async {
        var item = item
        // Countdowns start now, so a later pass doesn't find them expired.
        if item.expiresAt != nil { item.expiresAt = Date().addingTimeInterval(41.5) }
        let queue = ApprovalQueue()
        queue.enqueue(item) { _ in }
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
        }
        .padding(14)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
#endif
