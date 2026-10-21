import AppKit
import SwiftUI

@main
struct DoorbellMacApp: App {
    @State private var model = RingModel()

    var body: some Scene {
        WindowGroup("Doorbell spike (Mac)") {
            MacView().environment(model).frame(minWidth: 620, minHeight: 520)
        }
    }
}

struct MacView: View {
    @Environment(RingModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Set-up") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.accountStatus)
                    Text(model.listenerStatus)
                    ForEach(LocalAddresses.all(), id: \.address) { entry in
                        Text("\(entry.kind): \(entry.address)").textSelection(.enabled).monospaced()
                    }
                    Text("Type one of these addresses into the phone app.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                TextField("Tag", text: $model.tag).frame(width: 120)
                Button("Ring once") { Task { await model.ring() } }
                Divider().frame(height: 18)
                Stepper("\(model.count) rings", value: $model.count, in: 1...100).frame(width: 130)
                Stepper("every \(Int(model.interval)) s", value: $model.interval, in: 15...600, step: 15).frame(width: 140)
                if model.autoRemaining > 0 {
                    Button("Stop (\(model.autoRemaining) left)") { model.stopAuto() }
                } else {
                    Button("Start") { model.startAuto() }
                }
            }
            Table(model.rings) {
                TableColumn("#") { Text("\($0.seq)") }.width(30)
                TableColumn("Saved") { Text(format($0.saveSeconds, error: $0.saveError)) }
                TableColumn("Reached the Mac") { Text(format($0.deliverySeconds)) }
                TableColumn("Phone clock") { Text(format($0.phoneDelay)) }
                TableColumn("Via") { Text($0.ackPhase?.rawValue ?? "–") }
            }
            Text(model.summary).font(.callout).monospaced().textSelection(.enabled)
            HStack {
                Button("Copy Results") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.markdown, forType: .string)
                }
                Button("Delete Records from iCloud") { Task { await model.deleteRecords() } }
                Spacer()
                Text(model.status).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func format(_ seconds: Double?, error: String? = nil) -> String {
        if let error { return "error: \(error)" }
        return seconds.map { String(format: "%.2f s", $0) } ?? "–"
    }
}
