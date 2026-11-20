import FunesCore
import FunesProtocol
import SwiftUI

/// People & history's sheets (04-ux-mac.md): Rename…, Relation…, Merge With…, Set Dates…, Add Order… and the manual
/// entry (+ ▾).
enum PeopleSheet: Identifiable {
    case rename(PeopleDirectory.Entry)
    case relation(PeopleDirectory.Entry, PeopleEntityPage.Fact?)
    case merge(PeopleDirectory.Entry, [PeopleDirectory.Entry])
    case dates(String, PeopleDirectory.TimelineEpisode?)
    case order(PeopleDirectory.TimelineEpisode, [PeopleDirectory.TimelineEpisode])
    case manual(kind: String?, predicate: String?)

    var id: String {
        switch self {
        case let .rename(e): "rename|" + e.id
        case let .relation(e, _): "relation|" + e.id
        case let .merge(e, _): "merge|" + e.id
        case let .dates(f, e): "dates|" + f + (e?.id ?? "")
        case let .order(e, _): "order|" + e.id
        case let .manual(k, p): "manual|" + (k ?? "") + (p ?? "")
        }
    }
}

/// The relations you can pick for a kind: every predicate about that kind of thing, in the registry's words.
enum PeopleRelations {
    static func options(kind: String?, registry: FactsRegistry = .bundled) -> [(id: String, title: String)] {
        registry.predicates.filter { kind == nil || $0.objectKind == kind }.map { p in
            let noun = p.phrases["note_noun"] ?? p.id
            let title = (p.phrases["attribute"] ?? "{label}").replacingOccurrences(of: "{label}", with: noun)
            return (p.id, title.prefix(1).uppercased() + title.dropFirst())
        }
    }
}

struct PeopleSheetView: View {
    let sheet: PeopleSheet
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var label = ""
    @State private var predicate = ""
    @State private var other = ""
    @State private var start = ""
    @State private var end = ""
    @State private var kind = "person"
    @State private var status: FactAssertion.Status = .unknown
    @State private var sensitivity: Sensitivity = .internal

    private var people: PeopleModel { model.people }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            form
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Save")) { save(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: prepare)
        // A relation is about one kind of thing: another kind clears it.
        .onChange(of: kind) { _, k in
            if !predicate.isEmpty, FactsRegistry.bundled.kindOf(predicate) != k { predicate = "" }
        }
    }

    private var title: String {
        switch sheet {
        case .rename: String(localized: "Rename")
        case .relation: String(localized: "Relation")
        case .merge: String(localized: "Merge With")
        case .dates: String(localized: "Set Dates")
        case .order: String(localized: "Add Order")
        case .manual: String(localized: "Add Yourself")
        }
    }

    private var datesHint: some View {
        Text(String(localized: "A year, a month or a day: 2019, 2019-03 or 2019-03-15.")).font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var form: some View {
        switch sheet {
        case .rename:
            TextField(String(localized: "Name"), text: $text)
        case let .relation(e, f):
            relationPicker(kind: e.kind)
            if let f {
                Text(String(localized: "Replaces “\(f.attribute)”. You can undo it under Corrections."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField(String(localized: "Your word for it (optional): sister, girlfriend, wife"), text: $label)
        case let .merge(e, candidates):
            Picker(String(localized: "Merge into \(PeopleText.name(e))"), selection: $other) {
                Text(String(localized: "Choose…")).tag("")
                ForEach(candidates) { c in Text(PeopleText.name(c)).tag(c.id) }
            }
            Text(String(localized: "They become one. You can undo it under Corrections.")).font(.caption).foregroundStyle(.secondary)
        case .dates:
            TextField(String(localized: "Start"), text: $start)
            TextField(String(localized: "End (optional)"), text: $end)
            datesHint
        case let .order(e, others):
            Picker(String(localized: "Came just before \(e.name)"), selection: $other) {
                Text(String(localized: "Choose…")).tag("")
                ForEach(others) { o in
                    Text([o.name, PeopleText.range(start: o.start, end: o.end, ongoing: o.ongoing)].compactMap { $0 }.joined(separator: ", "))
                        .tag(o.id)
                }
            }
        case let .manual(k, p):
            TextField(String(localized: "Name"), text: $text)
            if k == nil && p == nil {
                Picker(String(localized: "Kind"), selection: $kind) {
                    ForEach(people.directory?.kinds ?? [], id: \.self) { Text(PeopleText.kind($0)).tag($0) }
                }
            }
            relationPicker(kind: kind, optional: p == nil)
            TextField(String(localized: "Your word for it (optional)"), text: $label)
            HStack {
                TextField(String(localized: "Start (optional)"), text: $start)
                TextField(String(localized: "End (optional)"), text: $end)
            }
            datesHint
            Picker(String(localized: "Now"), selection: $status) {
                Text(String(localized: "Not said")).tag(FactAssertion.Status.unknown)
                Text(String(localized: "Current")).tag(FactAssertion.Status.current)
                Text(String(localized: "Former")).tag(FactAssertion.Status.former)
            }
            Picker(String(localized: "Sensitivity"), selection: $sensitivity) {
                ForEach(Sensitivity.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text(String(localized: "Agents never see this. The cloud limit applies to it at this level."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func relationPicker(kind: String, optional: Bool = false) -> some View {
        Picker(String(localized: "Relation"), selection: $predicate) {
            if optional { Text(String(localized: "None")).tag("") }
            ForEach(PeopleRelations.options(kind: kind), id: \.id) { Text($0.title).tag($0.id) }
        }
    }

    private var canSave: Bool {
        switch sheet {
        case .rename: !text.trimmingCharacters(in: .whitespaces).isEmpty
        case .relation: !predicate.isEmpty
        case .merge, .order: !other.isEmpty
        case .dates: !start.isEmpty || !end.isEmpty
        case .manual: !text.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func prepare() {
        switch sheet {
        case let .rename(e): text = e.name ?? ""
        case let .relation(e, f):
            predicate = f?.predicate ?? PeopleRelations.options(kind: e.kind).first?.id ?? ""
            label = f?.label ?? ""
        case let .manual(k, p):
            kind = k ?? p.map { FactsRegistry.bundled.kindOf($0) } ?? "person"
            predicate = p ?? ""
        default: break
        }
    }

    private func save() {
        let s = start.trimmingCharacters(in: .whitespaces), e = end.trimmingCharacters(in: .whitespaces)
        Task {
            switch sheet {
            case let .rename(entry): await people.rename(entry.id, text)
            case let .relation(entry, fact):
                await people.setRelation(entry.id, predicate: predicate, label: label, replacing: fact?.factID)
            case let .merge(entry, _): await people.merge(other, into: entry.id)
            case let .dates(fid, ep): await people.setDates(fid, start: s, end: e, selector: ep?.selector)
            case let .order(ep, others):
                if let o = others.first(where: { $0.id == other }) { await people.addOrder(before: o, after: ep) }
            case .manual:
                await people.add(PeopleManualEntry(kind: kind, name: text, predicate: predicate.isEmpty ? nil : predicate,
                                                   label: label.isEmpty ? nil : label, start: s.isEmpty ? nil : s,
                                                   end: e.isEmpty ? nil : e, status: status, sensitivity: sensitivity))
            }
        }
    }
}
