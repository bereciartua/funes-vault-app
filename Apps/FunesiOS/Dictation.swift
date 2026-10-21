import AVFoundation
import FunesProtocol
import Observation
import os
import Speech

private let logger = Logger(subsystem: Identifiers.iOSLoggerSubsystem, category: "dictation")

/// Dictation into the Capture field: SpeechAnalyzer on iOS 26 and later, on this iPhone. Before
/// iOS 26 the mic button points to the keyboard's own dictation instead.
@MainActor @Observable
final class Dictation {
    enum State: Equatable {
        case idle
        case preparing
        case listening
        case failed(String)
    }

    private(set) var state = State.idle
    /// What's been said so far: final text, then the words still being worked out.
    private(set) var transcript = ""
    private var finalized = ""
    private var session: AnyObject?

    static var isAvailable: Bool {
        if #available(iOS 26, *) { true } else { false }
    }

    var isActive: Bool { state == .preparing || state == .listening }

    func start() async {
        guard #available(iOS 26, *), !isActive else { return }
        state = .preparing
        transcript = ""
        finalized = ""
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .failed(String(localized: "Funes can't use the microphone. Turn it on in Settings ▸ Funes Vault."))
            return
        }
        let session = DictationSession()
        self.session = session
        do {
            try await session.start { [weak self] text, isFinal in self?.heard(text, isFinal: isFinal) }
            if state == .preparing { state = .listening }
        } catch {
            logger.error("Dictation didn't start: \(String(describing: type(of: error)), privacy: .public)") // log-safe: an error type
            await session.stop()
            self.session = nil
            state = .failed(String(localized: "Dictation isn't available right now. Use the microphone on the keyboard instead."))
        }
    }

    /// Stops listening and returns everything heard.
    func stop() async -> String {
        guard #available(iOS 26, *), let session = session as? DictationSession else {
            state = .idle
            return transcript
        }
        await session.stop()
        self.session = nil
        state = .idle
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func heard(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized += text
            transcript = finalized
        } else {
            transcript = finalized + text
        }
    }
}

/// One dictation: the microphone through `AVAudioEngine`, converted to the analyzer's format,
/// into a `DictationTranscriber`. The model is downloaded once if this iPhone lacks it.
@available(iOS 26, *)
private final class DictationSession: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?

    func start(onResult: @escaping @MainActor (String, Bool) -> Void) async throws {
        let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en_US")
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationError.noFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        self.input = input
        results = Task {
            do {
                for try await result in transcriber.results {
                    await onResult(String(result.text.characters), result.isFinal)
                }
            } catch {
                logger.error("Dictation results ended: \(String(describing: type(of: error)), privacy: .public)") // log-safe: an error type
            }
        }
        try await analyzer.start(inputSequence: stream)

        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audio.setActive(true, options: .notifyOthersOnDeactivation)
        try startMicrophone(into: input, format: format)
    }

    /// Not on the main actor: the tap runs on the audio thread.
    private nonisolated func startMicrophone(into input: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) throws {
        let node = engine.inputNode
        let micFormat = node.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: micFormat, to: format) else { throw DictationError.noFormat }
        let box = ConverterBox(converter)
        node.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
            if let converted = box.convert(buffer, to: format) { input.yield(AnalyzerInput(buffer: converted)) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() async {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        results = nil
        analyzer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private enum DictationError: Error {
    case noFormat
}

/// The converter, used only from the audio thread's tap.
private final class ConverterBox: @unchecked Sendable {
    private let converter: AVAudioConverter

    init(_ converter: AVAudioConverter) { self.converter = converter }

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }
}
