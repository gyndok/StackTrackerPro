import SwiftUI

/// Full-screen voice capture: records with `DictationEngine` and hands the
/// finished transcript straight back to the caller via `onResult` — no
/// parsing, no structure inference. The transcript IS the product (verbatim
/// dictation design); the caller decides what to do with the raw string
/// (see `HandCaptureView`, which stores it on `HandCaptureModel.transcript`).
struct DictationSheet: View {
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
        .preferredColorScheme(.dark)
        .task {
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

    // MARK: - Transcript

    private var transcriptPlaceholder: String {
        showEmptyHint
            ? "Didn't catch anything — try again."
            : "Start speaking — describe the hand as it happened."
    }

    private var transcriptArea: some View {
        ScrollView {
            Text(engine.fullTranscript.isEmpty ? transcriptPlaceholder : engine.fullTranscript)
                .font(PokerTypography.chatBody)
                .foregroundColor(engine.fullTranscript.isEmpty
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
        if case .error = engine.state {
            Button("Retry") {
                Task { await engine.start() }
            }
            .buttonStyle(PokerButtonStyle(isEnabled: true))
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
            guard !transcript.isEmpty else {
                // Nothing captured — say so and resume listening rather than
                // stranding the user on a dead-end screen. Cancel (or a
                // swipe-dismiss) may have fired while stop() was in flight;
                // guard the resume so a post-teardown restart doesn't kick
                // the mic pipeline back on after the view is already gone.
                guard !cancelled else { return }
                showEmptyHint = true
                await engine.start()
                return
            }
            // Cancel may have fired (and the sheet dismissed) while stop()
            // was in flight; don't push a result into a torn-down flow.
            guard !cancelled else { return }
            onResult(transcript)
            dismiss()
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
