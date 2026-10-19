import BridgeKitRemote
import BridgeUI
import FunesCore
import FunesProtocol
import SwiftUI

// The agent's Cloud section (04-ux-mac.md; ADR-0018): Allow cloud access, the cloud agent's setup,
// its connected apps, and Copy Remote Token… / Reset Remote Token… / Connect a Cloud App….
// Adapted from EK Bridge's CloudSection (BridgeUI/Upstream/RemoteAccessView.swift, e753b22).

struct CloudTab: View {
    @Bindable var model: AppModel
    let agent: Agent
    @State private var choice: CloudAgent?
    @State private var oauthClient: OAuthClientDetails?

    private var cloudAgent: CloudAgent { choice ?? agent.agentKind.cloudAgent ?? .claudeAI }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !model.remoteAccess.active {
                    Label {
                        HStack(alignment: .firstTextBaseline) {
                            Text(model.remoteAccess.enabled
                                 ? String(localized: "Remote Access is on, but its tunnel address isn't set yet.")
                                 : String(localized: "Remote Access is off, so cloud agents can't reach Funes Vault."))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button(String(localized: "Set Up Remote Access…")) { model.show(.remoteAccess) }
                        }
                    } icon: { Image(systemName: "globe") }
                }
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(String(localized: "Allow cloud access"))
                                Text(agent.cloudAccess ? model.cloudSummary(agent)
                                                       : String(localized: "Off: cloud agents can't use this agent."))
                                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Toggle(String(localized: "Allow cloud access"), isOn: Binding(
                                get: { agent.cloudAccess }, set: { model.setCloudAccess(agent, $0) }))
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                        .padding(16)
                        if agent.cloudAccess { details }
                    }
                }
                if let message = model.cloudMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(String(localized: "Text you share with a cloud agent goes to its vendor's servers. Use one agent per cloud app, with only the access it needs."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .onDisappear { model.cloudMessage = nil }
        .sheet(item: $oauthClient) { details in OAuthClientSheet(details: details, done: { oauthClient = nil }) }
    }

    @ViewBuilder private var details: some View {
        RowDivider()
        ValueRow(label: String(localized: "Agent")) {
            Picker(String(localized: "Cloud agent"), selection: Binding(get: { cloudAgent }, set: { choice = $0 })) {
                ForEach(CloudAgent.allCases) { Text($0.name).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        } actions: {
            Pill(label: cloudAgent.usesOAuth ? "OAuth" : cloudAgent.usesRemoteToken ? String(localized: "Token") : "—")
        }
        RowDivider()
        ValueRow(label: String(localized: "MCP URL")) {
            if let url = model.remoteAccess.mcpURL {
                MonoText(text: url)
            } else {
                Text(String(localized: "Add the tunnel's address on the Remote Access page first.")).foregroundStyle(.secondary)
            }
        } actions: { EmptyView() }
        let snippet = CloudSetup.snippet(cloudAgent, context: CloudSetupContext(mcpURL: model.remoteAccess.mcpURL,
                                                                                 agentName: agent.name))
        RowDivider()
        VStack(alignment: .leading, spacing: 8) {
            // A bare URL is already in the row above.
            if !snippet.text.isEmpty, snippet.kind != .values || cloudAgent.usesRemoteToken {
                CodeBox(text: snippet.text, copy: true)
            }
            ForEach(Array(snippet.extraSnippets.enumerated()), id: \.offset) { _, extra in
                Text(extra.title).font(.callout).foregroundStyle(.secondary)
                CodeBox(text: extra.text, copy: true)
            }
            ForEach(Array(snippet.steps.enumerated()), id: \.offset) { index, step in
                Text(snippet.steps.count == 1 ? step : "\(index + 1). \(step)")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(cloudAgent.warnings(model.remoteAccess.names).enumerated()), id: \.offset) { _, warning in
                Label { Text(warning).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
            }
            if let footnote = cloudAgent.footnote {
                HStack(spacing: 4) {
                    Text(String(localized: "About \(cloudAgent.name)")).font(.callout).foregroundStyle(.secondary)
                    InfoButton(text: footnote)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        let apps = model.connectedApps(agent.id)
        if !apps.isEmpty {
            RowDivider()
            ForEach(apps) { app in
                ValueRow(label: app.id == apps.first?.id ? String(localized: "Connected") : "") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.appName)
                        Text([String(localized: "Connected \(app.createdAt.formatted(.dateTime.month(.abbreviated).day()))"),
                              app.lastUsedAt.map { String(localized: "last used \(RelativeTime.short($0, now: model.now))") }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } actions: {
                    Button(String(localized: "Revoke"), role: .destructive) { model.revokeApp(app) }
                }
            }
        }
        if let last = model.remoteServer?.connections[agent.id.db] {
            RowDivider()
            ValueRow(label: String(localized: "Last use")) {
                Text([last.agent.map { String(localized: "\($0) (as reported)") }, RelativeTime.short(last.at, now: model.now)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            } actions: { EmptyView() }
        }
        RowDivider()
        if model.pairingAgentID == agent.id {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Pairing is open. Connect the app in its settings now."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Spacer()
                tokenButtons
                appButtons
            }
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) { Spacer(); tokenButtons }
                HStack(spacing: 8) { Spacer(); appButtons }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var tokenButtons: some View {
            if agent.hasRemoteKey {
                Button(String(localized: "Reset Remote Token…")) { model.resetRemoteToken(agent) }
            }
            Button(String(localized: "Copy Remote Token…")) { model.copyRemoteToken(agent) }
                .modifier(Prominent(on: cloudAgent.usesRemoteToken))
    }

    @ViewBuilder private var appButtons: some View {
            if let redirect = cloudAgent.preRegisteredRedirectURI {
                Button(String(localized: "Set Up OAuth Client…")) {
                    oauthClient = model.setUpOAuthClient(agent, appName: cloudAgent.name, redirectURI: redirect)
                }
                .disabled(model.remoteAccess.mcpURL == nil)
            }
            Button(String(localized: "Connect a Cloud App…")) { model.connectCloudApp(agent) }
                .modifier(Prominent(on: cloudAgent.usesOAuth))
                .disabled(model.remoteAccess.mcpURL == nil)
                .help(model.remoteAccess.mcpURL == nil ? String(localized: "Add the tunnel's address on the Remote Access page first.") : "")
    }
}

/// Gemini Enterprise's OAuth client: the values to enter in its console. The secret is never
/// shown, only copied, and is gone once the sheet closes.
struct OAuthClientSheet: View {
    let details: OAuthClientDetails
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "OAuth Client")).font(.headline)
            Text(String(localized: "Enter these values in the app's OAuth settings. Pairing is open for 10 minutes; when the app asks you to sign in, check the code and allow it. If pairing has closed by then, open it again with Connect a Cloud App…."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                row(String(localized: "Authorization URL"), details.authorizationURL)
                row(String(localized: "Token URL"), details.tokenURL)
                row(String(localized: "Client ID"), details.clientID)
                GridRow {
                    Text(String(localized: "Client secret")).foregroundStyle(.secondary)
                    Text(verbatim: Identifiers.oauthClientSecretPrefix + " ••••••••••••••••").font(.body.monospaced())
                        .accessibilityLabel(String(localized: "Hidden"))
                    Button(String(localized: "Copy Secret")) { SecretClipboard.copy(details.secret) }
                }
                row(String(localized: "Scopes"), Identifiers.oauthScope)
                row(String(localized: "Redirect URI"), details.redirectURI)
            }
            Label(String(localized: "You can copy the secret only while this sheet is open. The clipboard is cleared after 90 seconds. If you lose it, click Set Up OAuth Client… again for a new one."),
                  systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(String(localized: "Done"), action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.body.monospaced()).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: value, help: String(localized: "Copy \(label)"))
        }
    }
}
