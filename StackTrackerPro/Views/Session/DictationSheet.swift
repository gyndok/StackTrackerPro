import SwiftUI

/// Full-screen voice capture: records with `DictationEngine`, then hands the
/// finished transcript to `HandTranscriptParser` to produce a
/// `ParsedHandDraft`. This view never touches `HandCaptureModel` directly —
/// mapping the draft onto the engine is the caller's job via `onResult`
/// (see `VoiceHandMapper`), keeping preview-before-commit intact.
struct DictationSheet: View {
    let context: HandContext
    let onResult: (ParsedHandDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var engine = DictationEngine()
    @State private var phase: Phase = .recording
    /// Snapshot of the transcript taken the moment `stop()` returns it, so it
    /// survives display through parsing/error phases even though the engine
    /// itself resets `fullTranscript` on its next `start()`.
    @State private var capturedTranscript = ""

    private enum Phase: Equatable {
        case recording
        case parsing
        case unavailable(String)
        case parseError(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer(minLength: 4)
                statusArea
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
    }

    // MARK: - Status area

    @ViewBuilder
    private var statusArea: some View {
        switch phase {
        case .recording:
            recordingStatus
        case .parsing:
            VStack(spacing: 12) {
                ProgressView().tint(.goldAccent)
                Text("Building your hand with on-device AI…")
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(.textSecondary)
            }
        case .unavailable(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundColor(.mZoneOrange)
                Text(message)
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.center)
            }
        case .parseError(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundColor(.chipRed)
                Text("Couldn't build the hand: \(message)")
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.center)
            }
        }
    }

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

    private var displayedTranscript: String {
        phase == .recording ? engine.fullTranscript : capturedTranscript
    }

    private var transcriptArea: some View {
        ScrollView {
            Text(displayedTranscript.isEmpty
                 ? "Start speaking — describe the hand as it happened."
                 : displayedTranscript)
                .font(PokerTypography.chatBody)
                .foregroundColor(displayedTranscript.isEmpty ? .textSecondary : .textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Action buttons

    @ViewBuilder
    private var actionButtons: some View {
        switch phase {
        case .recording:
            if case .error = engine.state {
                Button("Retry") {
                    Task { await engine.start() }
                }
                .buttonStyle(PokerButtonStyle(isEnabled: true))
            } else {
                Button("Done — Build Hand") {
                    doneBuildHand()
                }
                .buttonStyle(PokerButtonStyle(isEnabled: engine.state == .listening))
                .disabled(engine.state != .listening)
            }
        case .parsing:
            EmptyView()
        case .unavailable, .parseError:
            VStack(spacing: 12) {
                Button("Retry") {
                    Task { await runParse() }
                }
                .buttonStyle(PokerButtonStyle(isEnabled: true))
                Button("Cancel") { cancel() }
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(.textSecondary)
            }
        }
    }

    // MARK: - Actions

    private func doneBuildHand() {
        Task {
            let transcript = await engine.stop()
            guard !transcript.isEmpty else {
                // Nothing captured — resume listening rather than stranding
                // the user on a dead-end screen.
                await engine.start()
                return
            }
            capturedTranscript = transcript
            await runParse()
        }
    }

    private func runParse() async {
        guard HandTranscriptParser.shared.isAvailable else {
            phase = .unavailable(HandTranscriptParser.shared.statusMessage)
            return
        }
        phase = .parsing
        do {
            let draft = try await HandTranscriptParser.shared.parse(transcript: capturedTranscript, context: context)
            onResult(draft)
            dismiss()
        } catch {
            phase = .parseError(error.localizedDescription)
        }
    }

    private func cancel() {
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
