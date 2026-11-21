import FunesPhone
import FunesProtocol
import SwiftUI

/// People & history (UX: iPhone ▸ People & history, 13d.2): the Mac's section, read live, corrections only. Three
/// segments as the Mac's tabs: People & Names, Your Timeline, To Check. Pushed on Search's stack.
struct PeopleView: View {
    let model: PhoneModel
    private var people: PeopleModel { model.people }

    var body: some View {
        @Bindable var people = model.people
        List {
            if model.reachability.isConnected, people.directory != nil {
                Section {
                    Picker("Show", selection: $people.tab) {
                        Text("People & Names").tag(PeopleModel.Tab.people)
                        Text("Timeline").tag(PeopleModel.Tab.timeline)
                        Text(people.toCheckCount > 0 ? "To Check \(people.toCheckCount)" : "To Check").tag(PeopleModel.Tab.toCheck)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                banners
                switch people.tab {
                case .people: list
                case .timeline: PeopleTimelineSections(model: model)
                case .toCheck: PeopleToCheckSections(model: model)
                }
            }
        }
        .overlay { placeholder }
        .navigationTitle("People & History")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(NameSearch(on: people.tab == .people && people.directory != nil, query: $people.query))
        .toolbar {
            if people.tab == .people, let kinds = people.directory?.kinds {
                ToolbarItem {
                    Menu {
                        ForEach(kinds, id: \.self) { k in
                            Toggle(PeopleWording.kindPlural(k), isOn: Binding(get: { people.kinds.contains(k) }, set: { on in
                                if on { people.kinds.insert(k) } else { people.kinds.remove(k) }
                            }))
                        }
                    } label: {
                        Label("Kind", systemImage: people.kinds.isEmpty ? "line.3.horizontal.decrease.circle"
                                                                        : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filter by kind")
                    .accessibilityValue(people.kinds.isEmpty ? String(localized: "Every kind")
                                                             : people.kinds.sorted().map(PeopleWording.kindPlural).joined(separator: ", "))
                }
            }
        }
        .refreshable {
            // The list first; the status that follows finds it at its revision and reads nothing more.
            await people.load()
            Task { await model.refresh(fresh: true) }
        }
        .task { await people.appeared() }
    }

    @ViewBuilder private var banners: some View {
        if let d = people.directory, people.tab == .people {
            if !d.learning {
                Section { Text(PeopleWording.notLearning).font(.footnote).foregroundStyle(.secondary) }
            } else if let r = d.reading {
                Section { Text(PeopleWording.reading(r)).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private var list: some View {
        let entries = people.entries
        Section {
            ForEach(entries) { e in
                NavigationLink(value: SearchRoute.entity(e.id)) { PeopleRowView(entry: e) }
            }
        }
    }

    /// What shows over the list while there's nothing to list.
    @ViewBuilder private var placeholder: some View {
        if !model.reachability.isConnected {
            VaultUnavailableView(model: model, feature: .people)
        } else {
            switch people.phase {
            case .idle, .loading:
                if people.directory == nil { ProgressView() }
            case let .closed(reason):
                ContentUnavailableView {
                    Label("People & History", systemImage: "person.2")
                } description: {
                    Text(reason == PeopleUnavailable.namesUnavailable ? PeopleWording.namesUnavailable : PeopleWording.factsOff)
                }
            case let .failed(error):
                ContentUnavailableView {
                    Label("Couldn't read People & History", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(PhoneModel.vaultMessage(for: error))
                } actions: {
                    Button("Try Again") { Task { await people.load() } }
                }
            case .loaded:
                if people.tab == .people, people.entries.isEmpty {
                    if people.directory?.entries.isEmpty ?? true {
                        ContentUnavailableView {
                            Label("No One Yet", systemImage: "person.2")
                        } description: {
                            Text(people.directory?.reading.map(PeopleWording.reading) ?? PeopleWording.nothingYet)
                        }
                    } else {
                        ContentUnavailableView.search(text: people.query)
                    }
                }
            }
        }
    }
}

/// A row of People & names: the kind's icon, the name, the fact in a few words and the count; one VoiceOver element.
struct PeopleRowView: View {
    let entry: PeopleEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: PeopleWording.symbol(entry.kind)).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(PeopleWording.name(entry)).lineLimit(1)
                    if entry.manual { YouPill() }
                }
                if let f = entry.fact {
                    Text(PeopleWording.line(f)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(entry.mentions, format: .number).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PeopleWording.accessibility(entry))
    }
}

/// "You": something you made or corrected, as on the Mac.
struct YouPill: View {
    var body: some View {
        Text("You")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.18)))
    }
}

// MARK: Your timeline

struct PeopleTimelineSections: View {
    let model: PhoneModel

    var body: some View {
        let sections = model.people.directory?.timeline ?? []
        ForEach(sections, id: \.predicate) { s in
            Section {
                if !s.on {
                    Text(PeopleWording.timelineOff).font(.footnote).foregroundStyle(.secondary)
                }
                if s.episodes.isEmpty {
                    Text("Nothing here yet. Add a fact on your Mac.").foregroundStyle(.secondary)
                }
                ForEach(s.episodes) { e in
                    NavigationLink(value: SearchRoute.entity(e.entityID)) { PeopleEpisodeRow(episode: e, on: s.on) }
                }
            } header: {
                Text(PeopleWording.capitalized(s.noun))
            }
        }
    }
}

/// An episode as the Mac's timeline shows it: the entity, its dates, its kind, the title history, conflicts, gaps and
/// orders Funes can't decide, and its basis. With the timeline use off, only your entry as you entered it.
struct PeopleEpisodeRow: View {
    let episode: PeopleEpisode
    let on: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(episode.name).font(.body.weight(.medium))
                if let r = PeopleWording.range(start: episode.start, end: episode.end, ongoing: episode.ongoing) {
                    Text(r).foregroundStyle(.secondary)
                } else if episode.yours {
                    Text(PeopleWording.yourStatus(episode)).foregroundStyle(.secondary)
                }
            }
            if let k = episode.kind { Text(PeopleWording.slot(k)).font(.caption).foregroundStyle(.secondary) }
            if let t = PeopleWording.titles(episode.titles) { Text(t).font(.callout) }
            if let c = PeopleWording.conflict(episode) {
                Label(c, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            if let p = episode.previous.flatMap(PeopleWording.previous) { Text(p).font(.callout).foregroundStyle(.secondary) }
            let basis = on || episode.yours ? PeopleWording.basis(episode) : nil
            let line = [basis, PeopleWording.stating(episode.stating)].compactMap { $0 }.joined(separator: " · ")
            if !line.isEmpty { Text(line).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: To check

struct PeopleToCheckSections: View {
    let model: PhoneModel

    var body: some View {
        let items = (model.people.directory?.toCheck ?? []).filter { PeopleWording.question($0) != nil }
        Section {
            if items.isEmpty {
                Text(PeopleWording.toCheckEmpty).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(PeopleWording.question(item) ?? "")
                    let choices = PeopleWording.choices(item)
                    if !choices.isEmpty {
                        Text(choices.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } footer: {
            Text(PeopleWording.toCheckFooter)
        }
    }
}

/// Search names, only on People & Names with a list to filter (not the timeline, To check, or an empty state).
private struct NameSearch: ViewModifier {
    let on: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if on {
            content.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("Search names"))
        } else {
            content
        }
    }
}
