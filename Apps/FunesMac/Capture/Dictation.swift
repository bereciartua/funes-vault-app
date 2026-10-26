import AVFoundation
import FunesCore
import FunesProtocol
import os
import Speech
import SwiftUI

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "dictation")

/// Dictation into the capture box and Home's composer (FR-H-03): the microphone through
/// SpeechAnalyzer, on this Mac. macOS 26 and later; on macOS 15 there's no mic button, and the
/// system's own dictation still works in the field. The words are never logged.
@available(macOS 26, *)
@MainActor @Observable
final class Dictation {
    enum State: Equatable {
        case idle
        /// Asking for access, or fetching the language's model.
        case starting
        case listening
        case failed(String)
    }

    private(set) var state = State.idle
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?

    /// Listens until `stop()`, handing `update` the words so far: what's settled, then what may
    /// still change.
    func start(update: @escaping @MainActor (String) -> Void) async {
        guard state == .idle || state.isFailure else { return }
        state = .starting
        do {
            try await Self.askForAccess()
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) else {
                throw Failure(String(localized: "Dictation doesn't support your language yet."))
            }
            let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            guard state == .starting else { return }
            let engine = AVAudioEngine()
            let natural = engine.inputNode.outputFormat(forBus: 0)
            guard natural.channelCount > 0,
                  let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: natural) else {
                throw Failure(String(localized: "There's no microphone to listen with."))
            }
            let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.start(inputSequence: stream)
            // Stopped while the analyzer started.
            guard state == .starting else {
                input.finish()
                await analyzer.cancelAndFinishNow()
                return
            }
            results = Task { @MainActor in
                var settled = ""
                do {
                    for try await result in transcriber.results {
                        let words = String(result.text.characters)
                        if result.isFinal {
                            settled += words
                            update(settled)
                        } else {
                            update(settled + words)
                        }
                    }
                } catch {
                    logger.error("Dictation's results stopped")
                }
            }
            try Self.listen(engine, format: format, into: input)
            self.engine = engine
            self.analyzer = analyzer
            self.input = input
            state = .listening
        } catch let failure as Failure {
            state = .failed(failure.message)
        } catch {
            logger.error("Dictation didn't start")
            await stop()
            state = .failed(String(localized: "Dictation didn't start. Try again."))
        }
    }

    /// Stops listening; the last words are settled first.
    func stop() async {
        guard state == .listening || state == .starting else { return }
        state = .idle
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        engine = nil
        analyzer = nil
        input = nil
        results = nil
    }

    private struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// The microphone, then speech recognition, asked for the first time they're needed.
    private static func askForAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure(microphoneDenied) }
        default: throw Failure(microphoneDenied)
        }
        var speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .notDetermined {
            speech = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) } }
        }
        guard speech == .authorized else {
            throw Failure(String(localized: "Funes can't use speech recognition. Allow it in System Settings ▸ Privacy & Security ▸ Speech Recognition."))
        }
    }

    private static var microphoneDenied: String {
        String(localized: "Funes can't use the microphone. Allow it in System Settings ▸ Privacy & Security ▸ Microphone.")
    }

    /// Feeds the microphone to the analyzer, converted to the format it wants. Nonisolated: the
    /// tap runs on the audio thread, never the main actor.
    private nonisolated static func listen(_ engine: AVAudioEngine, format: AVAudioFormat,
                                           into input: AsyncStream<AnalyzerInput>.Continuation) throws {
        let node = engine.inputNode
        let natural = node.outputFormat(forBus: 0)
        let converter = natural == format ? nil : AVAudioConverter(from: natural, to: format)
        node.installTap(onBus: 0, bufferSize: 4_096, format: natural) { buffer, _ in
            guard let converter else {
                input.yield(AnalyzerInput(buffer: buffer))
                return
            }
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * format.sampleRate / natural.sampleRate).rounded(.up)) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var given = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, converted.frameLength > 0 { input.yield(AnalyzerInput(buffer: converted)) }
        }
        engine.prepare()
        try engine.start()
    }
}

@available(macOS 26, *)
private extension Dictation.State {
    var isFailure: Bool { if case .failed = self { true } else { false } }
}

/// The mic beside the field: dictates into it, keeping what was there; the text stays editable.
@available(macOS 26, *)
struct DictationButton: View {
    @Bindable var box: CaptureBoxModel
    @State private var dictation = Dictation()
    /// Which listening the words belong to: saving moves it on, so the last words of a dictation
    /// that ⏎ ended never land in the emptied field.
    @State private var session = Session()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @MainActor final class Session {
        var current = 0
    }

    var body: some View {
        Button(action: toggle) {
            Group {
                switch dictation.state {
                case .starting: ProgressView().controlSize(.small)
                case .listening:
                    Image(systemName: "mic.fill").foregroundStyle(.red)
                        .symbolEffect(.pulse, isActive: !reduceMotion)
                default: Image(systemName: "mic")
                }
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .help(dictation.state == .listening ? String(localized: "Stop Dictating") : String(localized: "Dictate"))
        .accessibilityLabel(dictation.state == .listening ? String(localized: "Stop Dictating") : String(localized: "Dictate"))
        .onChange(of: box.stopDictation) { _, _ in
            session.current += 1
            Task { await dictation.stop() }
        }
        .onChange(of: dictation.state) { _, state in
            if case .failed(let message) = state { box.error = message }
        }
        .onDisappear { Task { await dictation.stop() } }
    }

    private func toggle() {
        if dictation.state == .listening || dictation.state == .starting {
            Task { await dictation.stop() }
            return
        }
        box.error = nil
        let existing = box.text
        let lead = existing.isEmpty || existing.last?.isWhitespace == true ? existing : existing + " "
        box.focusRequest += 1
        session.current += 1
        let mine = session.current
        Task {
            await dictation.start { [box, session] words in
                guard session.current == mine else { return }
                box.text = lead + words
            }
        }
    }
}
