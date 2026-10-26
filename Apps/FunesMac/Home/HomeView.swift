import FunesCore
import FunesProtocol
import SwiftUI

/// Home (04-ux-mac.md ▸ Home, FR-H-02): where the window opens. The setup checklist until it's
/// dismissed, a greeting, a composer that saves captures as the capture box does, the vault's
/// pulse, four cards and a status line. No memory text or titles anywhere on it.
struct HomeView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                checklist
                VStack(alignment: .leading, spacing: 2) {
                    Text(HomeText.greeting(now: model.now, calledName: model.profile.calledName)).font(.title2.weight(.semibold))
                    Text(String(localized: "What should Funes remember?")).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                composer
                if let insights = model.home.insights {
                    PulseCard(model: model, insights: insights)
                    HomeCards(model: model, insights: insights)
                    statusLine(insights.overview)
                } else {
                    // The first read takes a few milliseconds; keep the page from jumping.
                    Color.clear.frame(height: 420)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.pane)
        .task {
            model.updateCloudChip(model.composer)
            await model.home.load()
        }
        .onChange(of: model.dataGeneration) { _, _ in Task { await model.home.load() } }
    }

    @ViewBuilder
    private var checklist: some View {
        if model.checklist.isVisible {
            SetupChecklistCard(model: model)
        } else if model.checklist.justHidden {
            HStack(spacing: 8) {
                Text(String(localized: "Setup checklist hidden. Settings ▸ Advanced brings it back."))
                    .foregroundStyle(.secondary)
                Button(String(localized: "Undo")) { model.checklist.undoHide() }
                    .keyboardShortcut("z", modifiers: .command)
                Spacer()
            }
            .font(.callout)
        }
    }

    /// The capture box's field in a card, with the mic and Remember, and its footer under it.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            CaptureField(box: model.composer, style: .home)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.separator.opacity(0.6), lineWidth: 0.5))
            CaptureFooter(box: model.composer, keys: String(localized: "⏎ Remember · ⌘⏎ Search vault"), centered: true)
                .frame(maxWidth: .infinity)
        }
    }

    /// "3 waiting in Inbox · Last tidy-up today 03:04", each part a link, each only when it has
    /// something to say.
    @ViewBuilder
    private func statusLine(_ overview: VaultOverview) -> some View {
        let waiting = model.inboxCount
        let tidied = overview.lastTidyUpAt
        if waiting > 0 || tidied != nil {
            HStack(spacing: 6) {
                if waiting > 0 {
                    Button(String(localized: "\(waiting) waiting in Inbox")) { model.show(.inbox) }
                }
                if waiting > 0, tidied != nil { Text(verbatim: "·").foregroundStyle(.secondary).accessibilityHidden(true) }
                if let tidied {
                    Button(String(localized: "Last tidy-up \(HomeText.when(tidied, now: model.now))")) { model.show(.inbox) }
                        .help(String(localized: "Its suggestions are in the Inbox"))
                }
            }
            .buttonStyle(.link)
            .font(.callout)
            .frame(maxWidth: .infinity)
        }
    }
}
