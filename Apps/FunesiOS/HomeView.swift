import FunesPhone
import FunesProtocol
import SwiftUI

/// The Home tab (UX: iPhone ▸ Home tab, FR-H-04), where the app opens: the composer (type or
/// dictate; **Remember** saves to the queue on this iPhone at once, and delivery follows), the
/// requests waiting for an answer, the vault's pulse and shape (counts only, never memory text),
/// who reads it, and Recent captures.
struct HomeView: View {
    let model: PhoneModel
    @State private var text = ""
    @State private var source = CaptureSource.typed
    @State private var dictation = Dictation()
    @State private var problem: String?
    @State private var saved = 0
    @State private var toast = false
    @FocusState private var focused: Bool

    private var capture: CaptureModel { model.capture }

    var body: some View {
        NavigationStack {
            List {
                composer
                ApprovalsSection(model: model)
                HomeOverview(model: model)
                if !capture.recent.isEmpty {
                    Section("Recent captures") {
                        ForEach(capture.recent.prefix(HomeView.recentShown)) { item in
                            recentRow(item)
                        }
                        if capture.recent.count > HomeView.recentShown {
                            NavigationLink("Show All") { AllCapturesView(model: model) }
                        }
                    }
                }
            }
            .navigationTitle(Self.greeting(Date()))
            .refreshable { await model.refresh(fresh: true) }
            .overlay(alignment: .bottom) {
                if toast {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .sensoryFeedback(.success, trigger: saved)
            .sheet(item: Bindable(model).pulseSheet) { range in PulseSheet(model: model, range: range) }
            .onChange(of: text) { problem = nil }
            .onChange(of: model.captureRequests, initial: true) { _, requests in
                guard requests > 0 else { return }
                // The Remember widget's 🎙: dictation where the app has its own, else the keyboard.
                if model.captureMode == .dictate, Dictation.isAvailable {
                    if !dictation.isActive { Task { await toggleDictation() } }
                } else {
                    focused = true
                }
            }
        }
    }

    /// Recent captures shows this many; Show All has the rest.
    static let recentShown = 5

    /// "Good morning", "Good afternoon" or "Good evening".
    static func greeting(_ now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        switch calendar.component(.hour, from: now) {
        case 5..<12: String(localized: "Good morning")
        case 12..<18: String(localized: "Good afternoon")
        default: String(localized: "Good evening")
        }
    }

    /// The composer: the old Capture tab's field, mic and **Remember**, unchanged.
    @ViewBuilder private var composer: some View {
        Section {
            editor
            if let problem {
                Label(problem, systemImage: "exclamationmark.octagon.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if case let .failed(message) = dictation.state {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Button(action: remember) {
                Text("Remember").bold().frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dictation.isActive)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    private func recentRow(_ item: CaptureModel.Recent) -> some View {
        RecentRow(item: item, isDemo: model.isDemo)
            .swipeActions {
                if item.status != .sent {
                    Button("Delete", role: .destructive) { capture.delete(item.id) }
                }
            }
    }

    private var editor: some View {
        HStack(alignment: .top) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty && !dictation.isActive {
                    Text("What should Funes remember?")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .accessibilityHidden(true)
                }
                TextEditor(text: dictation.isActive ? .constant(text + spoken) : $text)
                    .focused($focused)
                    .frame(minHeight: 96)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("What should Funes remember?")
            }
            micButton
        }
    }

    /// The dictation so far, after what was typed.
    private var spoken: String { Self.appending(dictation.transcript, to: text) }

    private static func appending(_ heard: String, to text: String) -> String {
        guard !heard.isEmpty else { return "" }
        return (text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") ? "" : " ") + heard
    }

    @ViewBuilder private var micButton: some View {
        if Dictation.isAvailable {
            Button {
                Task { await toggleDictation() }
            } label: {
                Image(systemName: dictation.isActive ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 34))
                    .symbolEffect(.pulse, isActive: dictation.state == .listening)
            }
            .buttonStyle(.plain)
            .foregroundStyle(dictation.isActive ? .red : .accentColor)
            .accessibilityLabel(dictation.isActive ? "Stop Dictation" : "Dictate")
        } else {
            // Before iOS 26: the keyboard's own dictation.
            Button {
                focused = true
            } label: {
                Image(systemName: "mic.circle")
                    .font(.system(size: 34))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("Dictate with the Keyboard")
            .accessibilityHint("Opens the keyboard. Tap its microphone to dictate.")
        }
    }

    private func toggleDictation() async {
        if dictation.isActive {
            let heard = await dictation.stop()
            if !heard.isEmpty {
                text += Self.appending(heard, to: text)
                source = .dictation
            }
        } else {
            focused = false
            await dictation.start()
        }
    }

    private func remember() {
        do {
            try capture.remember(text, source: source)
            text = ""
            source = .typed
            problem = nil
            saved += 1
            withAnimation { toast = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation { toast = false }
            }
        } catch {
            problem = CaptureModel.message(for: error)
        }
    }
}

/// Show All: every recent capture, with where it is.
struct AllCapturesView: View {
    let model: PhoneModel

    var body: some View {
        List {
            ForEach(model.capture.recent) { item in
                RecentRow(item: item, isDemo: model.isDemo)
                    .swipeActions {
                        if item.status != .sent {
                            Button("Delete", role: .destructive) { model.capture.delete(item.id) }
                        }
                    }
            }
        }
        .navigationTitle("Recent Captures")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RecentRow: View {
    let item: CaptureModel.Recent
    /// Demo captures are labelled as such (UX: iPhone, Demo mode).
    var isDemo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.text).lineLimit(2)
            HStack(spacing: 6) {
                status
                Spacer()
                Text(item.createdAt, style: .relative).foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var status: some View {
        switch item.status {
        case .sent where isDemo: Label("Sent to the demo Inbox", systemImage: "checkmark").foregroundStyle(.green)
        case .sent: Label("Sent to Mac", systemImage: "checkmark").foregroundStyle(.green)
        case .waiting: Label("Waiting", systemImage: "clock").foregroundStyle(.secondary)
        case let .rejected(code): Label(CaptureModel.message(for: code), systemImage: "xmark.octagon").foregroundStyle(.red)
        }
    }
}
