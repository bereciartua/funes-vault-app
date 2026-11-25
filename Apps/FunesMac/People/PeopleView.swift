import FunesCore
import FunesProtocol
import SwiftUI

/// Vault ▸ People & history (04-ux-mac.md, FR-F-07): People & names (the list and an entity's page), Your timeline,
/// and To check. Everything here is yours only: agents never see it.
struct PeopleView: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var sheet: PeopleSheet?

    private var people: PeopleModel { model.people }

    var body: some View {
        VStack(spacing: 0) {
            if !model.factsLearning && !model.hasUserFactEntries {
                PeopleEmptyState(kind: .off, model: model)
            } else if people.unavailable {
                Text(String(localized: "Funes can't read your names in Settings ▸ About You right now, so it shows nothing here."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                toolbar.padding(.horizontal, 16).padding(.vertical, 12)
                banners
                Divider()
                content
            }
        }
        .background(Palette.pane)
        .task { await people.load() }
        .onChange(of: model.memoriesGeneration) { _, _ in Task { await people.load() } }
        .sheet(item: $sheet) { s in PeopleSheetView(sheet: s, model: model) }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker(String(localized: "Show"), selection: Binding(get: { people.tab }, set: { people.tab = $0 })) {
                Text(String(localized: "People & Names")).tag(PeopleModel.Tab.people)
                Text(String(localized: "Your Timeline")).tag(PeopleModel.Tab.timeline)
                Text(people.toCheckCount > 0 ? String(localized: "To Check \(people.toCheckCount)") : String(localized: "To Check"))
                    .tag(PeopleModel.Tab.toCheck)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 8)
            if people.tab == .people {
                SearchField(text: Binding(get: { people.query }, set: { people.query = $0 }),
                            prompt: String(localized: "Search names"), focused: $searchFocused)
                    .frame(minWidth: 140, maxWidth: 220)
                Menu {
                    ForEach(people.directory?.kinds ?? [], id: \.self) { k in
                        Toggle(PeopleText.kindPlural(k), isOn: Binding(get: { people.kinds.contains(k) }, set: { on in
                            if on { people.kinds.insert(k) } else { people.kinds.remove(k) }
                        }))
                    }
                    Divider()
                    Toggle(String(localized: "Hidden"), isOn: Binding(get: { people.showHidden }, set: { people.showHidden = $0 }))
                } label: {
                    Text(people.kinds.isEmpty ? String(localized: "Kind") : String(localized: "Kind (\(people.kinds.count))"))
                }
                .fixedSize()
                .accessibilityLabel(String(localized: "Filter by kind"))
            }
            Menu {
                ForEach(people.directory?.kinds ?? [], id: \.self) { k in
                    Button(String(localized: "\(PeopleText.kind(k))…", comment: "+ menu: add a person, an organization…")) {
                        sheet = .manual(kind: k, predicate: nil)
                    }
                }
                Divider()
                Button(String(localized: "A Fact About You…")) { sheet = .manual(kind: nil, predicate: nil) }
            } label: {
                Label(String(localized: "Add"), systemImage: "plus")
            }
            .fixedSize()
            .help(String(localized: "Add a person, a place or a fact yourself"))
        }
        .controlSize(.small)
    }

    @ViewBuilder private var banners: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.factsLearning {
                HStack {
                    Text(String(localized: "Funes isn't learning from your memories. Your own entries and corrections are kept."))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "Open Settings")) { model.openSettings(.facts) }.buttonStyle(.link)
                }
            } else if let progress = model.factsBackfill, progress.state.isRunning {
                Text(String(localized: "Reading your memories: \(progress.done) of \(progress.total)")).foregroundStyle(.secondary)
            }
            if let summary = model.peopleSummary, let d = people.directory {
                HStack {
                    Image(systemName: "sparkles").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(PeopleText.summary(d.summary))
                    Spacer()
                    Button(String(localized: "Dismiss")) { model.dismissPeopleSummary(summary) }.buttonStyle(.link)
                }
                .accessibilityElement(children: .combine)
            }
            if let problem = people.problem {
                WarningLabel(text: problem)
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        switch people.tab {
        case .people:
            HSplitView {
                PeopleListView(model: model)
                    .frame(minWidth: 260, idealWidth: 330, maxWidth: 440, maxHeight: .infinity)
                Group {
                    if let page = people.page {
                        EntityPageView(page: page, model: model, sheet: $sheet)
                    } else {
                        Text(people.entries.isEmpty ? "" : String(localized: "Select a name"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 340, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.pane)
            }
        case .timeline:
            PeopleTimelineView(model: model, sheet: $sheet)
        case .toCheck:
            PeopleToCheckView(model: model)
        }
    }
}

// MARK: Empty states

struct PeopleEmptyState: View {
    enum Kind { case off, nothingYet }
    let kind: Kind
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2").font(.system(size: 36)).foregroundStyle(.secondary).accessibilityHidden(true)
            switch kind {
            case .off:
                Text(String(localized: "Funes can learn the people in your life and where you've worked from your memories, for your own search. Turn on Facts in Settings ▸ AI ▸ Features."))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button(String(localized: "Open Settings")) { model.openSettings(.facts) }
            case .nothingYet:
                if let progress = model.factsBackfill, progress.state.isRunning {
                    Text(String(localized: "Reading your memories: \(progress.done) of \(progress.total)"))
                } else {
                    Text(String(localized: "Funes hasn't learned anyone from your memories yet. It reads new and changed ones as you save them."))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }
        }
        .foregroundStyle(.secondary)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: The list

struct PeopleListView: View {
    let model: AppModel
    private var people: PeopleModel { model.people }

    var body: some View {
        Group {
            if people.loaded, people.directory?.entries.isEmpty ?? true {
                PeopleEmptyState(kind: .nothingYet, model: model)
            } else {
                List(selection: Binding(get: { people.selection }, set: { people.select($0) })) {
                    ForEach(people.entries) { e in
                        PeopleRow(entry: e).tag(e.id)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .accessibilityLabel(String(localized: "People & names"))
            }
        }
        .background(Palette.card)
    }
}

struct PeopleRow: View {
    let entry: PeopleDirectory.Entry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: PeopleText.symbol(entry.kind)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(PeopleText.name(entry)).lineLimit(1)
                    if entry.manual { Pill(label: String(localized: "You")) }
                    if entry.hidden { Image(systemName: "eye.slash").font(.caption).foregroundStyle(.secondary) }
                }
                if let f = entry.fact {
                    Text(PeopleText.line(f)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(entry.mentions, format: .number).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PeopleText.accessibility(entry))
    }
}

// MARK: An entity's page

struct EntityPageView: View {
    let page: PeopleEntityPage
    let model: AppModel
    @Binding var sheet: PeopleSheet?
    @State private var notThis: PeopleEntityPage.Fact?

    private var people: PeopleModel { model.people }
    private var entry: PeopleDirectory.Entry { page.entry }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if page.aliases.contains(where: { $0.alias != entry.name }) { aliases }
                section(String(localized: "About You")) {
                    if page.facts.isEmpty {
                        Text(String(localized: "Nothing about you yet.")).foregroundStyle(.secondary)
                    }
                    ForEach(page.facts) { f in factRow(f) }
                }
                section(String(localized: "Memories (\(page.memories.count))")) {
                    if page.memories.isEmpty {
                        Text(String(localized: "No memory mentions it now.")).foregroundStyle(.secondary)
                    }
                    ForEach(page.memories) { m in memoryRow(m) }
                }
                if !page.corrections.isEmpty {
                    section(String(localized: "Corrections")) {
                        ForEach(page.corrections) { c in
                            HStack {
                                Text(PeopleText.correction(c))
                                Spacer()
                                Button(String(localized: "Undo")) { Task { await people.undo(c.id) } }.buttonStyle(.link)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(notThis.map { String(localized: "\(PeopleText.name(entry)) isn't \($0.attribute)?") } ?? "",
                            isPresented: Binding(get: { notThis != nil }, set: { if !$0 { notThis = nil } }), presenting: notThis) { f in
            Button(f.recordedOnly ? String(localized: "Remove") : String(localized: "Not This"), role: .destructive) {
                Task { await people.rejectFact(f.factID) }
            }
        } message: { _ in
            Text(String(localized: "Funes stops using it in every memory. You can undo it under Corrections."))
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: PeopleText.symbol(entry.kind)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(PeopleText.name(entry)).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if entry.deceased { Pill(label: String(localized: "Deceased")) }
            if entry.tombstone {
                Pill(label: String(localized: "Only what you entered"))
                    .help(String(localized: "No memory mentions it now; Funes keeps what you typed or confirmed."))
            }
            Spacer()
            if entry.group == nil {
                Menu(PeopleText.kind(entry.kind)) {
                    ForEach(people.directory?.kinds ?? [], id: \.self) { k in
                        Button(PeopleText.kind(k)) { Task { await people.setKind(entry.id, k) } }.disabled(k == entry.kind)
                    }
                }
                .fixedSize()
                .accessibilityLabel(String(localized: "Kind: \(PeopleText.kind(entry.kind))"))
            }
            Menu {
                if entry.group == nil {
                    Button(String(localized: "Rename…")) { sheet = .rename(entry) }
                    Button(String(localized: "Add a Relation…")) { sheet = .relation(entry, nil) }
                    if entry.kind == "person" {
                        Button(entry.deceased ? String(localized: "Not Deceased") : String(localized: "Mark as Deceased")) {
                            Task { await people.setDeceased(entry.id, !entry.deceased) }
                        }
                    }
                    Button(String(localized: "Merge With…")) { sheet = .merge(entry, page.mergeCandidates) }
                        .disabled(page.mergeCandidates.isEmpty)
                }
                Button(entry.hidden ? String(localized: "Show in the List") : String(localized: "Hide")) {
                    Task { await people.setHidden(entry.id, !entry.hidden) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(String(localized: "Actions"))
        }
    }

    private var aliases: some View {
        let parts = page.aliases.filter { $0.alias != entry.name }.map { a in
            a.memories > 0 ? String(localized: "\(a.alias) (\(a.memories))", comment: "An alias and how many memories use it") : a.alias
        }
        return Text(String(localized: "Also called: \(parts.joined(separator: ", "))")).foregroundStyle(.secondary)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func factRow(_ f: PeopleEntityPage.Fact) -> some View {
        let dates = f.episodes.compactMap { PeopleText.range(start: $0.start, end: $0.end, ongoing: $0.ongoing) }
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(f.attribute.prefix(1).uppercased() + f.attribute.dropFirst())
                    if f.status == .former { Text(String(localized: "· former")).foregroundStyle(.secondary) }
                    if !dates.isEmpty { Text("· " + dates.joined(separator: ", ")).foregroundStyle(.secondary) }
                }
                Text(f.recordedOnly ? String(localized: "\(PeopleText.basis(f.basis)) · recorded only, not used in search")
                                    : PeopleText.basis(f.basis))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if f.recordedOnly {
                Button(String(localized: "Remove")) { notThis = f }.buttonStyle(.link)
            }
            Menu {
                if !f.recordedOnly { Button(String(localized: "Not This")) { notThis = f } }
                if entry.group == nil { Button(String(localized: "Change Relation…")) { sheet = .relation(entry, f) } }
                if f.episodes.count > 1 {
                    // One set of actions per episode: what you set stays with that episode.
                    ForEach(f.episodes) { e in
                        Section(PeopleText.range(start: e.start, end: e.end, ongoing: e.ongoing) ?? String(localized: "Undated")) {
                            episodeActions(f, e)
                        }
                    }
                } else {
                    episodeActions(f, f.episodes.first)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(String(localized: "Correct this"))
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func episodeActions(_ f: PeopleEntityPage.Fact, _ e: PeopleDirectory.TimelineEpisode?) -> some View {
        let former = e.map { $0.former || $0.inferredEnd } ?? (f.status == .former)
        Button(String(localized: "Mark as Former")) { Task { await people.setStatus(f.factID, .former, selector: e?.selector) } }
            .disabled(former)
        Button(String(localized: "Mark as Current")) { Task { await people.setStatus(f.factID, .current, selector: e?.selector) } }
            .disabled(!former)
        if f.dated {
            Button(String(localized: "Set Dates…")) { sheet = .dates(f.factID, e) }
            if e?.yourDates == true {
                Button(String(localized: "Clear Dates")) { if let e { Task { await people.clearDates(e) } } }
            }
        }
    }

    private func memoryRow(_ m: PeopleEntityPage.MemoryRow) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Button(m.title) { model.showMemory(m.memoryID) }
                    .buttonStyle(.plain)
                    .help(String(localized: "Show this memory"))
                if let line = m.whyLine {
                    WhyLineRow(line: line, notName: { t in Task { await people.notName(t) } },
                               notThis: { if let id = line.notThis, let f = page.facts.first(where: { $0.factID == id }) { notThis = f } })
                } else if m.untrusted {
                    Text(String(localized: "From text you didn't write")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(String(localized: "Not \(m.notName.name)", comment: "Why line correction: this memory isn't about them")) {
                Task { await people.notName(m.notName) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: String(localized: "Show this memory")) { model.showMemory(m.memoryID) }
        .accessibilityAction(named: String(localized: "Not \(m.notName.name)")) { Task { await people.notName(m.notName) } }
        .accessibilityAction(named: String(localized: "Not This")) {
            if let id = m.whyLine?.notThis, let f = page.facts.first(where: { $0.factID == id }) { notThis = f }
        }
    }
}

// MARK: Your timeline

struct PeopleTimelineView: View {
    let model: AppModel
    @Binding var sheet: PeopleSheet?
    private var people: PeopleModel { model.people }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(people.directory?.timeline ?? [], id: \.predicate) { s in section(s) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ s: PeopleDirectory.TimelineSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(s.noun.prefix(1).uppercased() + s.noun.dropFirst()).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(String(localized: "Add a Fact…")) {
                    sheet = .manual(kind: FactsRegistry.bundled.kindOf(s.predicate), predicate: s.predicate)
                }
                .controlSize(.small)
            }
            if !s.on {
                Text(String(localized: "Funes isn't ordering this now. Only what you enter shows here."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if s.episodes.isEmpty {
                Text(String(localized: "Nothing here yet.")).foregroundStyle(.secondary)
            }
            ForEach(s.episodes) { e in episodeRow(e, section: s) }
        }
    }

    private func episodeRow(_ e: PeopleDirectory.TimelineEpisode, section s: PeopleDirectory.TimelineSection) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Button(e.name) {
                        people.tab = .people
                        people.select(e.entity)
                    }
                    .buttonStyle(.plain)
                    .font(.body.weight(.medium))
                    if let r = PeopleText.range(start: e.start, end: e.end, ongoing: e.ongoing) {
                        Text(r).foregroundStyle(.secondary)
                    } else if e.yours {
                        // Only a status of yours, no dates: say which.
                        Text(e.former ? String(localized: "former", comment: "Timeline: a job of yours marked former, no dates")
                                      : String(localized: "current", comment: "Timeline: a job of yours marked current, no dates"))
                            .foregroundStyle(.secondary)
                    }
                    if let k = e.kind { Pill(label: k.replacingOccurrences(of: "_", with: " ")) }
                }
                if let t = PeopleText.titles(e.titles) { Text(t).font(.callout) }
                if let c = PeopleText.conflict(e) { WarningLabel(text: c) }
                if let p = e.previous { Text(PeopleText.previous(p)).font(.callout).foregroundStyle(.secondary) }
                HStack(spacing: 6) {
                    if s.on || e.yours, let b = PeopleText.basis(e) { Text(b) }
                    if e.stating.count == 1 { Text(String(localized: "· 1 memory says so")) }
                    else if e.stating.count > 1 { Text(String(localized: "· \(e.stating.count) memories say so")) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button(String(localized: "Set Dates…")) { sheet = .dates(e.factID, e) }
                if e.yourDates { Button(String(localized: "Clear Dates")) { Task { await people.clearDates(e) } } }
                Button(String(localized: "Mark as Current")) { Task { await people.setStatus(e.factID, .current, selector: e.selector) } }
                Button(String(localized: "Mark as Former")) { Task { await people.setStatus(e.factID, .former, selector: e.selector) } }
                if s.on {
                    Button(String(localized: "Add Order…")) { sheet = .order(e, s.episodes.filter { $0.factID != e.factID }) }
                        .disabled(s.episodes.count < 2)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(String(localized: "Correct this"))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.card))
        .accessibilityElement(children: .contain)       // its text, and its menu still reachable
    }
}

// MARK: To check

struct PeopleToCheckView: View {
    let model: AppModel
    private var people: PeopleModel { model.people }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let items = people.directory?.toCheck ?? []
                if items.isEmpty {
                    Text(String(localized: "Nothing to check. Funes asks here only what it couldn't settle; nothing waits on it."))
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    Card { row(item) }
                }
                if let answered = people.directory?.answered, !answered.isEmpty {
                    Text(String(localized: "ANSWERED")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(answered) { a in
                        HStack {
                            Text(a.skipped ? String(localized: "Skipped “\(a.surface)” in \(a.memoryTitle)")
                                           : String(localized: "“\(a.surface)” in \(a.memoryTitle) is someone else"))
                            Spacer()
                            Button(String(localized: "Undo")) { Task { await people.undo(a.group) } }.buttonStyle(.link)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func row(_ item: PeopleDirectory.ToCheckItem) -> some View {
        switch item {
        case let .link(l):
            Text(String(localized: "Who is “\(l.surface)” in \(l.memoryTitle)?", comment: "To check: an unsettled role phrase"))
            HStack {
                ForEach(l.candidates, id: \.entity) { c in
                    Button(c.name) { Task { await people.answer(l, .entity(c.entity)) } }
                }
                Button(String(localized: "Someone Else")) { Task { await people.answer(l, .someoneElse) } }
                Spacer()
                Button(String(localized: "Skip")) { Task { await people.answer(l, .skip) } }.buttonStyle(.link)
            }
        case let .merge(a, b, names):
            Text(String(localized: "Are \(names.first ?? "") and \(names.last ?? "") the same?", comment: "To check: a suggested merge"))
            HStack {
                Button(String(localized: "Merge")) { Task { await people.merge(b, into: a) } }
                Button(String(localized: "Not the Same")) { Task { await people.notSame(a, b) } }
            }
        case let .episode(e):
            let choices = e.choices.map { PeopleText.range(start: $0.lo > DateRange.minDay ? DateRange(lo: $0.lo, hi: $0.lo, precision: .year) : nil,
                                                           end: $0.hi < DateRange.maxDay ? DateRange(lo: $0.hi, hi: $0.hi, precision: .year) : nil,
                                                           ongoing: $0.hi >= DateRange.maxDay) ?? String(localized: "undated") }
            Text(choices.isEmpty
                 ? String(localized: "Something you set on \(e.name) (\(e.noun)) no longer matches one of its dates.")
                 : String(localized: "Which \(e.name) \(e.noun) did you mean?", comment: "To check: e.g. Which Acme job did you mean?"))
            HStack {
                ForEach(Array(zip(e.choices.indices, choices)), id: \.0) { i, text in
                    Button(text) { Task { await people.retarget(e, to: e.choices[i]) } }
                }
                Spacer()
                Button(String(localized: "Remove")) { Task { await people.retarget(e, to: nil) } }.buttonStyle(.link)
            }
        }
    }
}
