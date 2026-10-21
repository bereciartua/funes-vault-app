import FunesPhone
import FunesProtocol
import SwiftUI
import VisionKit

/// Pairing (UX: iPhone, Pairing flow): scan the Mac's code, then wait for **Allow** on the Mac.
struct PairingSheet: View {
    enum Step: Equatable {
        case scanning
        case waiting(macName: String)
        case paired(macName: String, seconds: Double)
        case failed(String)
    }

    let model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.scanning
    @State private var deviceName = DeviceInfo.name

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch step {
                case .scanning:
                    scanning
                case let .waiting(macName):
                    Spacer()
                    ProgressView()
                    Text("Click Allow on “\(macName)”")
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                    Text("Your Mac asks whether “\(deviceName)” may pair. This is the second check, so a photo of the code isn't enough.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                case let .paired(macName, seconds):
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.green)
                    Text("Paired with “\(macName)”")
                        .font(.title3.bold())
                    Text("Took \(seconds.formatted(.number.precision(.fractionLength(1)))) s")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                case let .failed(message):
                    Spacer()
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text(message)
                        .multilineTextAlignment(.center)
                    Spacer()
                    Button("Scan Again") { step = .scanning }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("Pair with Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .paired = step {} else { Button("Cancel") { dismiss() } }
                }
            }
            .interactiveDismissDisabled(step.isWaiting)
        }
    }

    @ViewBuilder private var scanning: some View {
        TextField("This iPhone's name", text: $deviceName)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.words)
        Text("Your Mac shows this name when it asks you to allow pairing.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
            QRScanner { code in scanned(code) }
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Text("Point the camera at the code in Funes Settings ▸ iPhone on your Mac.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            Spacer()
            Text("Scanning needs the camera. Allow camera access for Funes in Settings, then try again.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func scanned(_ code: String) {
        guard step == .scanning else { return }
        guard let payload = PairingQRPayload(qrString: code) else {
            step = .failed(String(localized: "That isn't a Funes pairing code."))
            return
        }
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        step = .waiting(macName: payload.macName)
        Task {
            do throws(CompanionClientError) {
                let elapsed = try await model.pair(payload, deviceName: name.isEmpty ? DeviceInfo.name : name)
                step = .paired(macName: payload.macName, seconds: Double(elapsed.milliseconds) / 1000)
            } catch {
                step = .failed(PhoneModel.message(for: error))
            }
        }
    }
}

extension PairingSheet.Step {
    var isWaiting: Bool {
        if case .waiting = self { return true }
        return false
    }
}

/// VisionKit's live scanner, for QR codes only. Reports each new code's text.
struct QRScanner: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: @MainActor (String) -> Void

        init(onCode: @escaping @MainActor (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case let .barcode(barcode) = item, let text = barcode.payloadStringValue { onCode(text) }
            }
        }
    }
}
