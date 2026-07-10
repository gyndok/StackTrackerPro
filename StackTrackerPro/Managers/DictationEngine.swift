import Foundation
import Observation
import os
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

    /// Incremented on every `start()`. The results task captures the value at
    /// spawn time and refuses to touch engine state (transcripts or `state`)
    /// once it no longer matches, so a stale task orphaned by a quick
    /// stop→start cannot append text to — or write an error into — the new
    /// session. `teardownAudio()` cancels the task but cannot await it (it is
    /// not async), which is exactly the window this guard closes.
    private var sessionGeneration = 0

    /// Bridges the audio-tap callback (an arbitrary, non-actor thread) into
    /// the analyzer's input stream. `AVAudioPCMBuffer` is not `Sendable`, so
    /// hopping it into a `@MainActor` `Task` per buffer (as the reference
    /// sketch did) fails Swift 6 strict concurrency checking ("sending
    /// 'buffer' risks causing data races"). Instead this bridge lives outside
    /// actor isolation — like `AnalyzerInput` itself, which the SDK marks
    /// `@unchecked Sendable` — and the tap closure calls it directly.
    ///
    /// Safety argument for `@unchecked Sendable`:
    /// - `isActive` is written from the MainActor (start/stop) while the tap
    ///   thread reads it, so it is guarded by an `OSAllocatedUnfairLock`.
    /// - `format` and `inputBuilder` are written by the MainActor only while
    ///   no tap is installed: set before `installTap`, cleared by `reset()`
    ///   only after `removeTap` (teardown removes the tap first). The tap
    ///   thread therefore never overlaps a write.
    /// - `converter` is created and used exclusively on the tap thread while
    ///   the tap is installed; `reset()` clears it only after `removeTap`.
    /// - `AsyncStream.Continuation` is itself Sendable/thread-safe, so the
    ///   MainActor calling `finish()` concurrently with a tap-thread `yield`
    ///   is fine.
    /// - CLOSURE-ISOLATION RULE (device crash, iOS 26.6): the tap closure
    ///   must capture only this bridge, be `@Sendable`, and be formed in a
    ///   nonisolated context — which is why `installTap(on:)` lives on the
    ///   bridge, not the engine. A closure created inside the engine's
    ///   `@MainActor start()` inherits MainActor isolation from its context
    ///   even when it captures nothing actor-isolated, and Swift 6's dynamic
    ///   actor-isolation checking (enabled by the `@preconcurrency`
    ///   AVFoundation import) then traps the instant AVFAudio invokes it on
    ///   the realtime messenger queue (`EXC_BREAKPOINT` in
    ///   `_swift_task_checkIsolatedSwift` → `dispatch_assert_queue_fail`).
    ///   Capturing the MainActor engine — or forming the closure in its
    ///   context — reinstates that executor-check trap.
    private final class AudioFeedBridge: @unchecked Sendable {
        var format: AVAudioFormat?
        var converter: AVAudioConverter?
        var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?

        private let activeFlag = OSAllocatedUnfairLock(initialState: false)
        var isActive: Bool {
            get { activeFlag.withLock { $0 } }
            set { activeFlag.withLock { $0 = newValue } }
        }

        /// Installs the mic tap with a closure that is nonisolated by
        /// construction: it is formed inside this (non-actor-isolated) bridge
        /// method, is explicitly `@Sendable` (which structurally strips any
        /// actor-isolation inference), and captures only the bridge itself.
        /// See the CLOSURE-ISOLATION RULE in the class doc-comment.
        func installTap(on node: AVAudioInputNode) {
            let micFormat = node.outputFormat(forBus: 0)
            isActive = true
            node.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { @Sendable [self] buffer, _ in
                feed(buffer)
            }
        }

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

        /// Only call after the tap has been removed (see safety argument).
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
        sessionGeneration += 1
        let generation = sessionGeneration

        state = .requestingPermission
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .error("Microphone access denied — enable it in Settings.")
            return
        }

        state = .preparingModel
        // Resolve the device locale to the transcriber's closest supported
        // equivalent; fall back to US English when the device language has no
        // on-device transcription model at all.
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
            ?? Locale(identifier: "en_US")
        do {
            try await Self.ensureLocaleReserved(locale)
        } catch {
            let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? "your language"
            state = .error("Couldn't prepare speech recognition for \(name) — \(error.localizedDescription)")
            return
        }
        do {
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
                do {
                    for try await result in transcriber.results {
                        guard let self, self.sessionGeneration == generation else { return }
                        let text = String(result.text.characters)
                        if result.isFinal {
                            self.finalizedTranscript += text + " "
                            self.volatileTranscript = ""
                        } else {
                            self.volatileTranscript = text
                        }
                    }
                } catch {
                    guard !Task.isCancelled,
                          let self, self.sessionGeneration == generation else { return }
                    self.state = .error("Transcription failed: \(error.localizedDescription)")
                }
            }

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            // The tap closure is created inside the bridge (nonisolated,
            // @Sendable) — forming it here in @MainActor context makes the
            // Swift runtime trap on the audio queue. See AudioFeedBridge's
            // CLOSURE-ISOLATION RULE.
            audioFeed.installTap(on: audioEngine.inputNode)
            audioEngine.prepare()
            try audioEngine.start()
            try await analyzer.start(inputSequence: stream)
            state = .listening
        } catch {
            teardownAudio()
            state = .error("Couldn't start dictation: \(error.localizedDescription)")
        }
    }

    /// Makes sure this app holds an AssetInventory reservation for `locale`
    /// before any asset status/installation query. On real hardware,
    /// `AssetInventory.assetInstallationRequest(supporting:)` throws
    /// "Cannot check the download status, <bundle id> is not subscribed to
    /// transcription.<lang>" for a locale the app hasn't reserved — the
    /// simulator never enforces this, which is why it only surfaced in
    /// device testing. The reservation is app-wide and persists across
    /// sessions (it is deliberately never released in `stop()`, so the model
    /// stays installed for the next dictation).
    private static func ensureLocaleReserved(_ locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        guard !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else { return }
        do {
            try await AssetInventory.reserve(locale: locale)
        } catch {
            // Most likely the per-app reservation limit
            // (`AssetInventory.maximumReservedLocales`). Dictation is this
            // app's only speech feature, so any other reservation is stale —
            // e.g. left over after the user changed device language. Release
            // them and retry once; rethrow if the retry still fails.
            for stale in reserved where stale.identifier(.bcp47) != locale.identifier(.bcp47) {
                await AssetInventory.release(reservedLocale: stale)
            }
            try await AssetInventory.reserve(locale: locale)
        }
    }

    func stop() async -> String {
        guard state == .listening else { return fullTranscript.trimmingCharacters(in: .whitespaces) }
        state = .stopping
        // Remove the tap FIRST so the tap thread goes quiet before any other
        // teardown state changes, then flag the bridge inactive and close the
        // input stream so the analyzer can finalize what it already has.
        audioEngine.inputNode.removeTap(onBus: 0)
        audioFeed.isActive = false
        audioFeed.inputBuilder?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        teardownAudio()
        state = .idle
        return fullTranscript.trimmingCharacters(in: .whitespaces)
    }

    /// Tears down every resource `start()` may have acquired, however far it
    /// got before succeeding or throwing. Order matters: the tap is removed
    /// first so the tap thread can no longer race the rest of the teardown
    /// (see AudioFeedBridge's safety argument). `resultsTask` must be
    /// cancelled here (not just in `stop()`): if `start()` fails after the
    /// task is created but before `analyzer.start(inputSequence:)` runs (e.g.
    /// `audioEngine.start()` throws), the task's captured `transcriber` keeps
    /// it alive independent of `self.transcriber`, and it would await
    /// `transcriber.results` forever since nothing is ever feeding the
    /// analyzer. Calling this from both the success and failure paths avoids
    /// that leak.
    private func teardownAudio() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil; transcriber = nil
        audioFeed.reset()
    }

    /// Backstop if the engine is deallocated mid-session (e.g. its owning
    /// sheet is torn down without awaiting `stop()`): silence the tap and
    /// stop the hardware. Stored properties are accessible from this
    /// nonisolated deinit because the instance is uniquely referenced at
    /// this point; none of these calls touch MainActor-isolated state.
    deinit {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioFeed.reset()
    }
}

private extension DictationEngine.State {
    var isError: Bool { if case .error = self { return true }; return false }
}
