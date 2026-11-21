import FunesPhone
import FunesProtocol
import SwiftUI

/// An entity's page (UX: iPhone ▸ People & history, 13d.2): its names, About you with each fact's basis in words, and the
/// memories that mention it with their why lines. **Not <name>** on a memory and **Not this** (Remove on a recorded-only
/// fact) are the only changes from the phone; they ask first where the Mac does.
struct PeopleEntityView: View {
    let model: PhoneModel
    let id: String
    @State private var notThis: PeopleFact?

    private var people: PeopleModel { model.people }

    var body: some View {
        List {
            if model.reachability.isConnected, let page = people.page {
                header(page)
                if page.aliases.contains(where: { $0.alias != page.entry.name }) {
                    Section { Text(aliases(page)).foregroundStyle(.secondary) }
                }
                Section("About You") {
                    if page.facts.isEmpty {
                        Text("Nothing about you yet.").foregroundStyle(.secondary)
                    }
                    ForEach(page.facts) { f in factRow(f, entry: page.entry) }
                }
                Section {
                    if page.memories.isEmpty {
                        Text("No memory mentions it now.").foregroundStyle(.secondary)
                    }
                    ForEach(page.memories) { m in memoryRow(m) }
                } header: {
                    Text("Memories (\(page.memories.count))")
                } footer: {
                    Text(PeopleWording.macOnly)
                }
            }
        }
        .overlay { placeholder }
        .navigationTitle(people.page.map { PeopleWording.name($0.entry) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await people.loadPage(id)
            Task { await model.refresh(fresh: true) }
        }
        .task { await people.openPage(id) }
        .onDisappear { closeIfLeaving() }
        .confirmationDialog(notThis.flatMap { f in people.page.map { PeopleWording.notThisQuestion($0.entry, f) } } ?? "",
                            isPresented: Binding(get: { notThis != nil }, set: { if !$0 { notThis = nil } }),
                            titleVisibility: .visible, presenting: notThis) { f in
            Button(f.recordedOnly ? String(localized: "Remove") : String(localized: "Not This"), role: .destructive) {
                if let t = f.notThis { Task { await people.correct(t) } }
            }
        } message: { _ in
            Text("Funes stops using it in every memory. You can undo it on your Mac.")
        }
        .alert(correctionTitle, isPresented: Binding(get: { people.correctionFailure != nil },
                                                     set: { if !$0 { people.dismissCorrectionFailure() } })) {
            Button("OK") { people.dismissCorrectionFailure() }
        } message: {
            Text(correctionMessage)
        }
    }

    /// Popped (not covered by a memory it opened): the page goes.
    private func closeIfLeaving() {
        if !model.searchPath.contains(.entity(id)) { people.closePage(id) }
    }

    @ViewBuilder private func header(_ page: PeopleEntityResult) -> some View {
        let e = page.entry
        Section {
            HStack(spacing: 10) {
                Image(systemName: PeopleWording.symbol(e.kind)).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(PeopleWording.name(e)).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text(PeopleWording.kind(e.kind)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            let tags = [e.manual ? String(localized: "You") : nil, e.deceased ? String(localized: "Deceased") : nil,
                        e.hidden ? String(localized: "Hidden") : nil, e.tombstone ? String(localized: "Only what you entered") : nil]
                .compactMap { $0 }
            if !tags.isEmpty {
                Text(tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func aliases(_ page: PeopleEntityResult) -> String {
        let parts = page.aliases.filter { $0.alias != page.entry.name }.map { a in
            a.memories > 0 ? String(localized: "\(a.alias) (\(a.memories))", comment: "An alias and how many memories use it") : a.alias
        }
        return String(localized: "Also called: \(parts.joined(separator: ", "))")
    }

    private func factRow(_ f: PeopleFact, entry: PeopleEntry) -> some View {
        let dates = f.episodes.compactMap { PeopleWording.range(start: $0.start, end: $0.end, ongoing: $0.ongoing) }
        let title = ([PeopleWording.capitalized(f.attribute)] + (f.status == .former ? [String(localized: "former")] : []) + dates)
            .joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(PeopleWording.basisLine(f)).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            if f.notThis != nil {
                Button(f.recordedOnly ? String(localized: "Remove") : String(localized: "Not This"), role: .destructive) { notThis = f }
            }
        }
        .accessibilityActions {
            if f.notThis != nil {
                Button(f.recordedOnly ? String(localized: "Remove") : String(localized: "Not This")) { notThis = f }
            }
        }
        .swipeActions {
            if f.notThis != nil {
                Button(f.recordedOnly ? String(localized: "Remove") : String(localized: "Not This"), role: .destructive) { notThis = f }
            }
        }
    }

    private func memoryRow(_ m: PeopleMemoryRow) -> some View {
        NavigationLink(value: SearchRoute.memory(m.memoryID)) {
            VStack(alignment: .leading, spacing: 3) {
                Text(m.title).lineLimit(2)
                if let why = m.why {
                    Label(why, systemImage: "link").font(.caption).foregroundStyle(.secondary)
                } else if m.untrusted {
                    Text("From text you didn't write").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .contextMenu {
            if let t = m.notName {
                Button(t.label ?? String(localized: "Not this")) { Task { await people.correct(t) } }
                    .disabled(people.correcting)
            }
        }
        .accessibilityActions {
            if let t = m.notName {
                Button(t.label ?? String(localized: "Not this")) { Task { await people.correct(t) } }
            }
        }
    }

    @ViewBuilder private var placeholder: some View {
        if !model.reachability.isConnected {
            VaultUnavailableView(model: model, feature: .people)
        } else if people.page == nil {
            switch people.pagePhase {
            case .idle, .loading, .loaded:
                ProgressView()
            case let .closed(reason):
                ContentUnavailableView {
                    Label("People & History", systemImage: "person.2")
                } description: {
                    Text(reason == PeopleUnavailable.namesUnavailable ? PeopleWording.namesUnavailable : PeopleWording.factsOff)
                }
            case let .failed(error):
                if case let .method(e) = error, e.code == .notFound {
                    ContentUnavailableView("No longer in People & History", systemImage: "person.crop.circle.badge.questionmark")
                } else {
                    ContentUnavailableView {
                        Label("Couldn't read this page", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(PhoneModel.vaultMessage(for: error))
                    } actions: {
                        Button("Try Again") { Task { await people.loadPage(id) } }
                    }
                }
            }
        }
    }

    /// Only two reach the alert: changed on the Mac (`target_changed`), or the Mac not reachable.
    private var correctionTitle: String {
        if case .method = people.correctionFailure { return String(localized: "Couldn't correct that") }
        return String(localized: "Mac not reachable")
    }

    private var correctionMessage: String {
        guard let failure = people.correctionFailure else { return "" }
        if case .method = failure { return String(localized: "It changed on your Mac. The page is up to date now; try again if it's still wrong.") }
        return PhoneModel.vaultMessage(for: failure)
    }
}
