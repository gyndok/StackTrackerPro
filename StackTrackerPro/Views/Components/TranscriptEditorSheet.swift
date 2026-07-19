import SwiftUI

/// Pure merge rule for resume-after-edit dictation: joins a manually-edited
/// base transcript with newly-dictated speech captured after a resume.
/// `DictationEngine.start()` resets `finalizedTranscript`/`volatileTranscript`
/// to empty on every call (fresh buffer, never accumulates across restarts —
/// see `DictationEngine.swift`), so a resume always needs to explicitly stitch
/// the pre-resume edited text back onto the freshly-captured speech; this is
/// the one place that stitching rule lives, and it is unit-tested in
/// isolation from the engine/sheet.
enum TranscriptMerge {
    /// Trimmed `base` + a single space + trimmed `newSpeech`. Either side
    /// empty collapses to just the other side, trimmed — so resuming from an
    /// empty edit or capturing no new speech never leaves a stray leading/
    /// trailing space.
    static func joined(base: String, newSpeech: String) -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNew = newSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBase.isEmpty { return trimmedNew }
        if trimmedNew.isEmpty { return trimmedBase }
        return "\(trimmedBase) \(trimmedNew)"
    }
}

/// Shared transcript editor, used both mid-capture (`HandCaptureModel.transcript`)
/// and on already-saved hands (`Hand.notes`). `warnIfEmptiedWithoutStructure`
/// drives the dictated-only warning copy — when true, saving an emptied
/// transcript would leave the hand with no logged content at all, so a
/// confirmation gate protects against an accidental total wipe. `onSave`
/// receives the trimmed final text (never the raw, possibly-whitespace-padded
/// `TextEditor` contents).
struct TranscriptEditorSheet: View {
    let initialText: String
    let warnIfEmptiedWithoutStructure: Bool
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var showEmptyConfirm = false

    init(initialText: String, warnIfEmptiedWithoutStructure: Bool, onSave: @escaping (String) -> Void) {
        self.initialText = initialText
        self.warnIfEmptiedWithoutStructure = warnIfEmptiedWithoutStructure
        self.onSave = onSave
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 200)
                .scrollContentBackground(.hidden)
                .background(Color.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(16)
                .background(Color.backgroundPrimary.ignoresSafeArea())
                .navigationTitle("Edit Transcript")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .foregroundColor(.textSecondary)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { attemptSave() }
                            .foregroundColor(.goldAccent)
                    }
                }
        }
        .alert("Clear Transcript?", isPresented: $showEmptyConfirm) {
            Button("Clear", role: .destructive) {
                onSave("")
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("This hand has no logged actions; clearing the transcript leaves it empty.")
        }
    }

    private func attemptSave() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if warnIfEmptiedWithoutStructure && trimmed.isEmpty {
            showEmptyConfirm = true
            return
        }
        onSave(trimmed)
        dismiss()
    }
}
