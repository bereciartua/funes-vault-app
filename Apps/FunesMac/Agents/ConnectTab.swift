import AppKit
import BridgeKitCore
import BridgeUI
import FunesCore
import FunesProtocol
import os
import SwiftUI

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "one-click")

/// Connect (04-ux-mac.md, FR-A-06..08): one-click setup with a preview and a backup, copyable setups
/// for the rest, the launcher path, Copy Key… and Rotate Key….
struct ConnectTab: View {
    let model: AppModel
    let agent: Agent
    @State private var target: SetupAgent = .other
    @State private var method: SetupMethod = .launcher
    /// The change waiting in the sheet. The sheet is presented from this value itself, so it never
    /// opens before the preview is there (an empty sheet with no buttons, Funes 0.1.0 Release).
    @State private var pending: PendingPreview?
    @State private var preparing = false
    @State private var oneClickError: OneClickFailure?
    @State private var result: OneClickResult?
    @State private var confirmCopyKey = false
    @State private var confirmRotate = false
    @State private var keyMessage: String?

    #if FUNES_UI_REVIEW
    /// The UI-review build sets this to open the one-click sheet through Add to <Agent>…'s own path.
    @MainActor static var reviewStartsOneClick: SetupAgent?
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(String(localized: "Set up for")).foregroundStyle(.secondary)
                    Picker(String(localized: "Set up for"), selection: $target) {
                        ForEach(SetupAgent.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
                if !agent.access.operations.isEmpty, agent.firstRequestAt == nil {
                    Label(String(localized: "Funes shows Connected here after the first request from \(agent.name)."),
                          systemImage: "clock")
                        .font(.callout).foregroundStyle(.secondary)
                } else if agent.access.operations.isEmpty {
                    Label(String(localized: "\(agent.name) has no access yet. It can connect, but sees nothing until you change its access."),
                          systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if target.oneClick { oneClickCard }
                snippetCard
                details
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            target = agent.agentKind.setupAgent
            method = target.recommended
            #if FUNES_UI_REVIEW
            if let review = Self.reviewStartsOneClick {
                Self.reviewStartsOneClick = nil
                target = review
                method = review.recommended
                startPreview(review)
            }
            #endif
        }
        .task {
            // Add and Connect…: show the one-click change once the Add sheet has gone (UX review F9).
            guard model.pendingOneClick == agent.id else { return }
            model.pendingOneClick = nil
            try? await Task.sleep(for: .milliseconds(450))
            let setup = agent.agentKind.setupAgent
            if setup.oneClick {
                target = setup
                startPreview(setup)
            }
        }
        .onChange(of: target) { _, agent in
            method = agent.recommended
            result = nil
            oneClickError = nil
        }
        .sheet(item: $pending) { pending in
            ConfigPreviewSheet(preview: pending.preview, agentName: agent.name) { confirmed in
                self.pending = nil
                if confirmed { apply(pending.preview) }
            }
        }
        .confirmationDialog(String(localized: "Copy \(agent.name)'s key?"), isPresented: $confirmCopyKey) {
            Button(String(localized: "Copy Key")) { copyKey() }
        } message: {
            Text(String(localized: "Anyone with this key can ask Funes for memories as \(agent.name). Paste it only into \(agent.name)'s settings, and never into a project file. Setups that use the launcher don't need it."))
        }
        .confirmationDialog(String(localized: "Rotate \(agent.name)'s key?"), isPresented: $confirmRotate) {
            Button(String(localized: "Rotate Key")) { rotate() }
        } message: {
            Text(String(localized: "The old key stops working at once. Setups that use the launcher keep working; any setup with the key pasted in needs the new one."))
        }
    }

    private var context: SetupContext { model.setupContext(for: agent) }

    // MARK: One click

    private var oneClickCard: some View {
        Card {
            Text(String(localized: "One-click setup")).font(.headline)
            Text(String(localized: "Funes shows the exact change first, backs up the file and never writes the key into it."))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "Add to \(target.displayName)…")) { startPreview(target) }
                    .buttonStyle(.borderedProminent)
                    .disabled(preparing)
                if preparing { ProgressView().controlSize(.small) }
                if let result {
                    if result.alreadySetUp {
                        Label(String(localized: "Already set up"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label(String(localized: "Added"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        if OneClickAgents.bundleID(target) != nil {
                            Button(String(localized: "Restart \(target.displayName)")) {
                                model.setupControls.restart(target) { _ in }
                            }
                        }
                    }
                }
            }
            if result != nil, agent.firstRequestAt == nil {
                // The first approved request is the point of setup: suggest one.
                Text(agent.access.askBeforeSharing
                     ? String(localized: "Then ask \(target.displayName): “What do you know about how I like to work?” Funes shows you exactly what it would share.")
                     : String(localized: "Then ask \(target.displayName): “What do you know about how I like to work?”"))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let backup = result?.backup {
                Text(String(localized: "Backup: \(backup.path)")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let output = result?.output, !output.isEmpty { CodeBox(text: output) }
            if let oneClickError {
                Label(oneClickError.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let output = oneClickError.output, !output.isEmpty { CodeBox(text: output) }
                if oneClickError.copyInstead {
                    Text(String(localized: "Use the setup below instead.")).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Builds the change, then shows it in the sheet; a failure shows its reason in the card. Logs
    /// name only the agent kind and the outcome, never the file's contents or path.
    private func startPreview(_ target: SetupAgent) {
        result = nil
        oneClickError = nil
        preparing = true
        let kind = target.rawValue
        model.setupControls.preview(target, context) { outcome in
            preparing = false
            switch outcome {
            case .success(let preview):
                logger.info("One-click preview ready for \(kind, privacy: .public)") // log-safe: an agent kind
                pending = PendingPreview(preview: preview)
            case .failure(let failure):
                logger.error("One-click preview failed for \(kind, privacy: .public)") // log-safe: an agent kind
                oneClickError = failure
            }
        }
    }

    private func apply(_ preview: OneClickPreview) {
        let kind = preview.agent.rawValue
        model.setupControls.apply(preview) { outcome in
            switch outcome {
            case .success(let done):
                logger.info("One-click setup applied for \(kind, privacy: .public)") // log-safe: an agent kind
                result = done
            case .failure(let failure):
                logger.error("One-click setup failed for \(kind, privacy: .public)") // log-safe: an agent kind
                oneClickError = failure
            }
        }
    }

    // MARK: Snippets

    private var snippetCard: some View {
        let snippet = target.snippet(method, context)
        return Card {
            HStack {
                Text(target.oneClick ? String(localized: "Or set it up yourself") : String(localized: "Setup")).font(.headline)
                Spacer()
                if target.methods.count > 1 {
                    Picker(String(localized: "Method"), selection: $method) {
                        ForEach(target.methods, id: \.self) { method in
                            Text(method == .launcher ? String(localized: "Launcher") : String(localized: "Direct HTTP")).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            ForEach(Array(snippet.steps.enumerated()), id: \.offset) { index, step in
                Text("\(index + 1). \(step)").fixedSize(horizontal: false, vertical: true)
            }
            CodeBox(text: snippet.text, copy: true)
            ForEach(Array(snippet.extraSnippets.enumerated()), id: \.offset) { _, extra in
                Text(extra.title).font(.callout).foregroundStyle(.secondary)
                CodeBox(text: extra.text, copy: true)
            }
            if let url = snippet.installURL {
                Button(String(localized: "Install in VS Code")) { NSWorkspace.shared.open(url) }
            }
            if let destination = snippet.destination {
                Text(String(localized: "Goes in \(destination)")).font(.caption).foregroundStyle(.secondary)
            }
            if snippet.skipsListenerCheck {
                Text(String(localized: "With this method the agent sends the key without checking that the program on the port is Funes Vault. The launcher checks first."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let note = target.footnote(model.setupNames) {
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Launcher and key

    private var details: some View {
        Card {
            Text(String(localized: "Details")).font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(String(localized: "Launcher")).foregroundStyle(.secondary)
                    MonoText(text: context.launcherPath)
                }
                GridRow {
                    Text(String(localized: "Agent ID")).foregroundStyle(.secondary)
                    MonoText(text: context.agentID)
                }
                GridRow {
                    Text(String(localized: "MCP URL")).foregroundStyle(.secondary)
                    MonoText(text: context.url)
                }
                GridRow {
                    Text(String(localized: "Key")).foregroundStyle(.secondary)
                    Text(agent.keyIssuedAt.map { String(localized: "Issued \($0.formatted(date: .abbreviated, time: .shortened))") }
                         ?? String(localized: "No key"))
                }
            }
            HStack {
                Button(String(localized: "Copy Key…")) { confirmCopyKey = true }
                Button(String(localized: "Rotate Key…")) { confirmRotate = true }
                if let keyMessage { Text(keyMessage).font(.callout).foregroundStyle(.secondary) }
            }
        }
    }

    private func copyKey() {
        guard let url = model.services.keys.url(agentID: agent.id),
              let key = try? String(contentsOf: url, encoding: .utf8) else {
            keyMessage = String(localized: "The key file couldn't be read. Rotate the key to make a new one.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        keyMessage = String(localized: "Copied. Funes clears the clipboard in 60 seconds.")
        let count = NSPasteboard.general.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
    }

    private func rotate() {
        Task {
            do {
                _ = try await model.services.agents.rotateKey(agentID: agent.id, now: Date())
                keyMessage = String(localized: "New key issued. The old one no longer works.")
                await model.refresh()
            } catch {
                keyMessage = ErrorText.message(error)
            }
        }
    }
}

/// A preview for `.sheet(item:)`: a new identity each time, so every Add to <Agent>… shows its own.
private struct PendingPreview: Identifiable {
    let id = UUID()
    let preview: OneClickPreview
}

/// The change Add to <Agent>… would make: the file's diff, or the agent's own command.
struct ConfigPreviewSheet: View {
    let preview: OneClickPreview
    let agentName: String
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Add Funes Vault to \(preview.agent.displayName)?")).font(.title3.weight(.semibold))
            switch preview {
            case .file(_, let change):
                Text(change.summary).foregroundStyle(.secondary)
                Text(change.fileURL.path).font(.caption.monospaced()).textSelection(.enabled)
                if change.outcome == .unchanged {
                    Label(String(localized: "Nothing to change: it's already set up."), systemImage: "checkmark.circle")
                } else {
                    DiffBox(lines: change.diffLines)
                    if change.before != nil {
                        Text(String(localized: "Funes backs up the file next to it first."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            case .command(_, let executable, let arguments, _, let replacing):
                Text(replacing ? String(localized: "Funes runs this command, replacing the existing funes entry:")
                               : String(localized: "Funes runs this command:"))
                    .foregroundStyle(.secondary)
                CodeBox(text: ([executable] + arguments).map { $0.contains(" ") || $0.contains("\"") ? "'\($0)'" : $0 }.joined(separator: " "))
            }
            Text(String(localized: "The key isn't written anywhere: the launcher reads it from Funes's key file."))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { done(false) }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Add")) { done(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}

struct DiffBox: View {
    let lines: [DiffLine]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(prefix(line.kind) + line.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(line.kind == .added ? Color.green : line.kind == .removed ? Color.red : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.kind == .added ? Color.green.opacity(0.08) : line.kind == .removed ? Color.red.opacity(0.08) : .clear)
                }
            }
            .padding(8)
        }
        .frame(maxHeight: 240)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.separator))
        .accessibilityLabel(String(localized: "Changes to the file"))
    }

    private func prefix(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: "+ "
        case .removed: "- "
        case .context: "  "
        }
    }
}

/// Monospaced text with a Copy button.
struct CodeBox: View {
    let text: String
    var copy = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if copy {
                Button(copied ? String(localized: "Copied") : String(localized: "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                .padding(6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.separator))
    }
}

struct MonoText: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "Copy \(text)"))
        }
    }
}
