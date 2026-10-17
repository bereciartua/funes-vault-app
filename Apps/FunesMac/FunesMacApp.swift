import AppKit
import BridgeKitCore
import FunesCore
import FunesMCP
import FunesProtocol
import os

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "app")

@main
enum FunesMacApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

/// The menu bar shell until Phase 3 (spec/plans/phase-3-mac-app.md), with the vault and the MCP
/// server running: agents connect through funes-mcp and answer in the approval panels.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var environment: VaultEnvironment?
    private var approvals: FunesApprovals?
    private var mcp: FunesMCPServer?
    private var minuteTimer: Timer?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        do {
            let environment = try VaultEnvironment()
            self.environment = environment
            let approvals = FunesApprovals(environment: environment)
            self.approvals = approvals
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let mcp = FunesMCPServer(services: environment.services, presenter: approvals,
                                     dataFolder: environment.dataFolder, version: version)
            mcp.statusChanged = { [weak self] _ in self?.updateMenu() }
            self.mcp = mcp
            Task {
                #if DEBUG
                await DevSeed.runIfAsked(environment)
                #endif
                mcp.start()
            }
            startMinuteJob(environment)
            logger.info("Launched")
        } catch {
            logger.error("The vault didn't open")
            statusLine.title = String(localized: "The vault didn't open")
        }
        updateMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Open panels are refused (`funes_quit`); the endpoint file goes with the listener.
        approvals?.queue.withdrawAll()
        mcp?.stop()
    }

    /// Pending requests past their 15 minutes are denied, and old suggestions expire (access
    /// policy §3.9).
    private func startMinuteJob(_ environment: VaultEnvironment) {
        let job: @Sendable () -> Void = {
            _ = Task {
                _ = try? await environment.disclosures.expirePending(now: Date())
                _ = try? await environment.suggestions.expire(now: Date())
            }
        }
        job()
        let timer = Timer(timeInterval: 60, repeats: true) { _ in job() }
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: "Funes Vault")
        let menu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let title = NSMenuItem(title: "Funes Vault \(version)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Funes Vault", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private func updateMenu() {
        let paused = environment?.pause.isPaused(at: Date()) ?? false
        pauseItem.title = paused ? String(localized: "Resume Funes Vault") : String(localized: "Pause Funes Vault")
        guard let mcp else { return }
        switch mcp.service.status {
        case .off: statusLine.title = String(localized: "Agents: off")
        case .starting: statusLine.title = String(localized: "Agents: starting…")
        case .listening(let port):
            statusLine.title = paused ? String(localized: "Agents: paused") : String(localized: "Agents: on, port \(port)")
        case .failed(.portInUse(let port)): statusLine.title = String(localized: "Agents: port \(port) is in use")
        case .failed: statusLine.title = String(localized: "Agents: the server stopped")
        }
    }

    /// "Pause Funes Vault" (FR-A-11): every agent request is refused with `funes_paused`.
    @objc private func togglePause() {
        guard let environment else { return }
        if environment.pause.isPaused(at: Date()) {
            environment.pause.resume()
        } else {
            environment.pause.pause(until: .distantFuture)
            approvals?.queue.withdrawAll()
        }
        updateMenu()
    }
}
