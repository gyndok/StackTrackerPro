import SwiftUI

/// Full-screen voice capture: records with `DictationEngine` and hands the
/// finished transcript straight back to the caller via `onResult` — no
/// parsing, no structure inference. The transcript IS the product (verbatim
/// dictation design); the caller decides what to do with the raw string
/// (see `HandCaptureView`, which stores it on `HandCaptureModel.transcript`).
struct DictationSheet: View {
    /// DEBUG screenshot-demo pose: when non-nil, renders the listening state
    /// with this verbatim text in the transcript area WITHOUT ever starting
    /// the engine (see `.task` below) — the mic and speech APIs are never
    /// touched. Defaulted so every existing call site keeps compiling
    /// unchanged.
    var previewTranscript: String? = nil
    let onResult: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var engine = DictationEngine()
    /// Transient hint shown in the transcript placeholder after Done was
    /// tapped with nothing captured; cleared as soon as new speech arrives.
    @State private var showEmptyHint = false
    /// Set once Cancel is tapped (or the sheet is torn down via swipe) so a
    /// late-resolving stop() doesn't still fire `onResult` into a dismissed
    /// flow.
    @State private var cancelled = false

    /// Manually-edited transcript text once the engine has left `.listening`
    /// (Done/stop). `nil` while still listening (the live read-only display
    /// is shown instead); seeded exactly once from the engine's transcript
    /// the moment stop() resolves. Editing here never touches the engine —
    /// it's a pure post-capture text override.
    @State private var editedText: String? = nil
    /// True once "Resume" is tapped after a manual edit, pending the
    /// confirmation alert below.
    @State private var resumeConfirm = false
    /// The edited text stashed just before a confirmed resume restarts the
    /// engine, so the next stop can stitch it back onto the fresh speech
    /// (`DictationEngine.start()` always resets its transcript buffers —
    /// see DictationEngine.swift — so nothing here can rely on the engine
    /// accumulating across a restart).
    @State private var resumeBase: String? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer(minLength: 4)
                recordingStatus
                transcriptArea
                actionButtons
            }
            .padding(20)
            .navigationTitle("Voice Hand Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                        .foregroundColor(.textSecondary)
                }
            }
        }
        .alert("Resume dictation?", isPresented: $resumeConfirm) {
            Button("Resume") { confirmResume() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New speech will be appended to your edited text.")
        }
        .preferredColorScheme(.dark)
        .task {
            // Screenshot-demo pose: never start the engine (no mic, no
            // speech APIs) when a preview transcript is supplied.
            if previewTranscript != nil { return }
            await engine.start()
        }
        .onDisappear {
            // Swipe-to-dismiss bypasses the Cancel/Done paths, and the
            // engine's deinit backstop can only silence the tap — it can't
            // deactivate the shared AVAudioSession (leaving the system record
            // indicator on) or cancel any in-flight work. onDisappear is
            // synchronous and the view is already gone, so capture the engine
            // and run the full graceful stop detached. stop() is idempotent
            // for non-listening states via its guard, so the Cancel/Done
            // paths hitting it a second time here is harmless. Setting
            // `cancelled` here is safe for the success path too: there
            // `onResult` fires BEFORE the programmatic dismiss, so this flag
            // only ever blocks post-dismissal delivery.
            cancelled = true
            let engine = self.engine
            Task { _ = await engine.stop() }
        }
    }

    // MARK: - Status area

    @ViewBuilder
    private var recordingStatus: some View {
        if previewTranscript != nil {
            // Screenshot-demo pose: render the listening UI without a live
            // engine session.
            PulsingMicIndicator()
        } else {
            switch engine.state {
            case .idle:
                VStack(spacing: 12) {
                    ProgressView().tint(.goldAccent)
                    Text("Getting ready…")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)
                }
            case .requestingPermission:
                VStack(spacing: 12) {
                    ProgressView().tint(.goldAccent)
                    Text("Requesting microphone access…")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)
                }
            case .preparingModel:
                VStack(spacing: 12) {
                    ProgressView().tint(.goldAccent)
                    Text("Downloading speech model…")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)
                }
            case .listening:
                PulsingMicIndicator()
            case .stopping:
                VStack(spacing: 12) {
                    ProgressView().tint(.goldAccent)
                    Text("Finishing up…")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)
                }
            case .error(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundColor(.chipRed)
                    Text(message)
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textPrimary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    // MARK: - Transcript

    private var transcriptPlaceholder: String {
        showEmptyHint
            ? "Didn't catch anything — try again."
            : "Start speaking — describe the hand as it happened."
    }

    /// The demo preview transcript (when posing) or the engine's live
    /// transcript — same display path either way.
    private var displayedTranscript: String {
        previewTranscript ?? engine.fullTranscript
    }

    @ViewBuilder
    private var transcriptArea: some View {
        if previewTranscript == nil, editedText != nil {
            // Post-stop review/edit phase: the engine has already stopped
            // (see `useTranscript()`) and handed over a plain-text buffer
            // the user can correct before committing. Bound directly to
            // `editedText` — never back to the engine, which is idle here.
            TextEditor(text: Binding(get: { editedText ?? "" }, set: { editedText = $0 }))
                .font(PokerTypography.chatBody)
                .foregroundColor(.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            liveTranscriptArea
        }
    }

    /// The live, read-only transcript display shown while listening (or,
    /// for the DEBUG pose, always). Unchanged from the pre-editing behavior.
    private var liveTranscriptArea: some View {
        ScrollView {
            Text(displayedTranscript.isEmpty ? transcriptPlaceholder : displayedTranscript)
                .font(PokerTypography.chatBody)
                .foregroundColor(displayedTranscript.isEmpty
                                 ? (showEmptyHint ? .mZoneOrange : .textSecondary)
                                 : .textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: engine.fullTranscript) { _, newValue in
            if showEmptyHint, !newValue.isEmpty { showEmptyHint = false }
        }
    }

    // MARK: - Action buttons

    @ViewBuilder
    private var actionButtons: some View {
        if previewTranscript != nil {
            // Screenshot-demo pose: render the listening-state button without
            // wiring it to a live engine.
            Button("Use Transcript") {}
                .buttonStyle(PokerButtonStyle(isEnabled: true))
        } else if case .error = engine.state {
            Button("Retry") {
                Task { await engine.start() }
            }
            .buttonStyle(PokerButtonStyle(isEnabled: true))
        } else if editedText != nil {
            // Post-stop review/edit phase: let the user either commit the
            // (possibly corrected) text or resume dictating more, merging
            // new speech onto what's already been edited.
            VStack(spacing: 12) {
                Button("Use Transcript") {
                    commitEditedTranscript()
                }
                .buttonStyle(PokerButtonStyle(isEnabled: true))
                Button("Resume") {
                    resumeConfirm = true
                }
                .foregroundColor(.textSecondary)
            }
        } else {
            Button("Use Transcript") {
                useTranscript()
            }
            .buttonStyle(PokerButtonStyle(isEnabled: engine.state == .listening))
            .disabled(engine.state != .listening)
        }
    }

    // MARK: - Actions

    private func useTranscript() {
        Task {
            let transcript = await engine.stop()
            guard !cancelled else { return }
            if let resumeBase {
                // Resumed from a manual edit: the engine buffer is fresh
                // (DictationEngine.start() resets it — see DictationEngine.
                // swift), so stitch the pre-resume base back onto whatever
                // new speech (if any) came in, and land back in the edit
                // phase rather than the empty-hint auto-restart below —
                // the base text is real content even if nothing new was
                // captured this time.
                self.resumeBase = nil
                editedText = TranscriptMerge.joined(base: resumeBase, newSpeech: transcript)
                return
            }
            guard !transcript.isEmpty else {
                // Nothing captured — say so and resume listening rather than
                // stranding the user on a dead-end screen. Cancel (or a
                // swipe-dismiss) may have fired while stop() was in flight;
                // guard the resume so a post-teardown restart doesn't kick
                // the mic pipeline back on after the view is already gone.
                showEmptyHint = true
                await engine.start()
                return
            }
            // Move into the post-stop review/edit phase rather than
            // committing immediately, so the user can correct
            // speech-to-text mistakes before the transcript is handed back.
            editedText = transcript
        }
    }

    /// Commits whatever is in `editedText` (the user's corrected text, or the
    /// untouched engine transcript if they made no changes) and closes the
    /// sheet. Only reachable from the post-stop edit phase, where the engine
    /// is already idle — no `stop()` call here.
    private func commitEditedTranscript() {
        guard !cancelled else { return }
        onResult(editedText ?? engine.fullTranscript)
        dismiss()
    }

    /// Confirmed via the `resumeConfirm` alert: stash the current edit as the
    /// merge base, drop back to the live listening view, and restart the
    /// engine. The next `useTranscript()` stop stitches this base onto
    /// whatever fresh speech comes in. The restart Task is guarded on
    /// `cancelled` both before and after the await (mirroring the stop-path
    /// Tasks): a swipe-dismiss can land mid-restart, and onDisappear's
    /// detached stop() no-ops via its `.listening` guard while start() is
    /// still in flight — without the post-await stop here, that race would
    /// leave the mic session running after the sheet is gone.
    private func confirmResume() {
        resumeBase = editedText
        editedText = nil
        showEmptyHint = false
        Task {
            guard !cancelled else { return }
            await engine.start()
            if cancelled { _ = await engine.stop() }
        }
    }

    private func cancel() {
        cancelled = true
        Task { await engine.stop() }
        dismiss()
    }
}

// MARK: - Pulsing mic indicator

private struct PulsingMicIndicator: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.chipRed.opacity(0.25))
                .frame(width: 96, height: 96)
                .scaleEffect(isPulsing ? 1.15 : 0.85)
                .opacity(isPulsing ? 0.35 : 0.9)
            Image(systemName: "mic.fill")
                .font(.system(size: 32))
                .foregroundColor(.chipRed)
                .frame(width: 72, height: 72)
                .background(Color.chipRed.opacity(0.15))
                .clipShape(Circle())
        }
        .onAppear { isPulsing = true }
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)
    }
}
