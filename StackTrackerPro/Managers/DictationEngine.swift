import Foundation
import Observation
@preconcurrency import AVFoundation
import Speech

/// On-device dictation: AVAudioEngine mic tap streamed into the iOS 26
/// SpeechAnalyzer. Audio and transcript never leave the device.
@MainActor @Observable
final class DictationEngine {
    enum State: Equatable {
        case idle, requestingPermission, preparingModel, listening, stopping
        case error(String)
    }

    private(set) var state: State = .idle
    private(set) var finalizedTranscript = ""
    private(set) var volatileTranscript = ""
    var fullTranscript: String { finalizedTranscript + volatileTranscript }

    /// Whether the on-device SpeechTranscriber module is available on this
    /// hardware/OS combination. This is a hardware/API capability check, not
    /// a per-locale asset-download check — see the deviation notes in the
    /// Task 3 report for why a synchronous `static var` can't reach the
    /// async asset-installation APIs.
    static var isSupported: Bool {
        SpeechTranscriber.isAvailable
    }

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var resultsTask: Task<Void, Never>?

    /// Bridges the audio-tap callback (an arbitrary, non-actor real-time
    /// thread) into the analyzer's input stream. `AVAudioPCMBuffer` is not
    /// `Sendable`, so hopping it into a `@MainActor` `Task` per buffer (as
    /// the reference sketch did) fails Swift 6 strict concurrency checking
    /// ("sending 'buffer' risks causing data races"). Instead this bridge
    /// lives outside actor isolation — like `AnalyzerInput` itself, which
    /// the SDK marks `@unchecked Sendable` — and the tap closure calls it
    /// directly. AVAudioEngine invokes the tap serially on one thread, so
    /// the unguarded mutable state here is safe in practice.
    private final class AudioFeedBridge: @unchecked Sendable {
        var format: AVAudioFormat?
        var converter: AVAudioConverter?
        var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
        var isActive = false

        func feed(_ buffer: AVAudioPCMBuffer) {
            guard isActive, let format else { return }
            if buffer.format == format {
                inputBuilder?.yield(AnalyzerInput(buffer: buffer))
                return
            }
            if converter == nil { converter = AVAudioConverter(from: buffer.format, to: format) }
            guard let converter,
                  let out = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(format.sampleRate / 10)) else { return }
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                status.pointee = .haveData
                return buffer
            }
            if error == nil { inputBuilder?.yield(AnalyzerInput(buffer: out)) }
        }

        func reset() {
            isActive = false
            format = nil
            converter = nil
            inputBuilder = nil
        }
    }

    private let audioFeed = AudioFeedBridge()

    func start() async {
        guard state == .idle || state.isError else { return }
        finalizedTranscript = ""; volatileTranscript = ""

        state = .requestingPermission
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .error("Microphone access denied — enable it in Settings.")
            return
        }

        state = .preparingModel
        do {
            let locale = Locale.current
            let transcriber = SpeechTranscriber(locale: locale,
                                                transcriptionOptions: [],
                                                reportingOptions: [.volatileResults],
                                                attributeOptions: [])
            self.transcriber = transcriber
            // Download the on-device model if this locale isn't installed yet.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            audioFeed.format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

            let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
            audioFeed.inputBuilder = builder

            resultsTask = Task { [weak self] in
                guard let transcriber = self?.transcriber else { return }
                do {
                    for try await result in transcriber.results {
                        guard let self else { return }
                        let text = String(result.text.characters)
                        if result.isFinal {
                            self.finalizedTranscript += text + " "
                            self.volatileTranscript = ""
                        } else {
                            self.volatileTranscript = text
                        }
                    }
                } catch {
                    self?.state = .error("Transcription failed: \(error.localizedDescription)")
                }
            }

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let inputNode = audioEngine.inputNode
            let micFormat = inputNode.outputFormat(forBus: 0)
            let audioFeed = self.audioFeed
            audioFeed.isActive = true
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
                audioFeed.feed(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            try await analyzer.start(inputSequence: stream)
            state = .listening
        } catch {
            teardownAudio()
            state = .error("Couldn't start dictation: \(error.localizedDescription)")
        }
    }

    func stop() async -> String {
        guard state == .listening else { return fullTranscript.trimmingCharacters(in: .whitespaces) }
        state = .stopping
        audioFeed.isActive = false
        audioFeed.inputBuilder?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        teardownAudio()
        state = .idle
        return fullTranscript.trimmingCharacters(in: .whitespaces)
    }

    /// Tears down every resource `start()` may have acquired, however far it
    /// got before succeeding or throwing. In particular `resultsTask` must be
    /// cancelled here (not just in `stop()`): if `start()` fails after the
    /// task is created but before `analyzer.start(inputSequence:)` runs (e.g.
    /// `audioEngine.start()` throws), the task's local `transcriber` binding
    /// keeps it alive independent of `self.transcriber`, and it would await
    /// `transcriber.results` forever since nothing is ever feeding the
    /// analyzer. Calling this from both the success and failure paths avoids
    /// that leak.
    private func teardownAudio() {
        resultsTask?.cancel()
        resultsTask = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        analyzer = nil; transcriber = nil
        audioFeed.reset()
    }
}

private extension DictationEngine.State {
    var isError: Bool { if case .error = self { return true }; return false }
}
