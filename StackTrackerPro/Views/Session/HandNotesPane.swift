import SwiftUI
import SwiftData

extension HandNote: Identifiable {
    var id: PersistentIdentifier { persistentModelID }
}

struct HandNotesPane: View {
    @Environment(TournamentManager.self) private var tournamentManager
    @Environment(CashSessionManager.self) private var cashSessionManager
    var tournament: Tournament? = nil
    var cashSession: CashSession? = nil

    @State private var showAddSheet = false
    @State private var editingNote: HandNote?
    @State private var noteText = ""

    /// Compute hand notes from whichever session is provided
    private var handNotes: [HandNote] {
        if let tournament {
            return tournament.sortedHandNotes
        } else if let cashSession {
            return cashSession.sortedHandNotes
        }
        return []
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if handNotes.isEmpty {
                    emptyState
                } else {
                    // Add button at top
                    addNoteButton
                        .padding(.horizontal, 12)
                        .padding(.top, 8)

                    LazyVStack(spacing: 8) {
                        ForEach(handNotes) { note in
                            handNoteRow(note)
                                .onTapGesture {
                                    beginEditing(note)
                                }
                                .contextMenu {
                                    Button {
                                        beginEditing(note)
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        deleteNote(note)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            addEditSheet(isNew: true)
        }
        .sheet(item: $editingNote) { note in
            addEditSheet(isNew: false, existingNote: note)
        }
    }

    // MARK: - Hand Note Row

    private func handNoteRow(_ note: HandNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top line: time, level badge, blinds, stack
            HStack(spacing: 8) {
                Text(note.timestamp, format: .dateTime.hour().minute())
                    .font(PokerTypography.chatCaption)
                    .foregroundColor(.textSecondary)

                if note.blindLevelNumber > 0 {
                    Text("Lvl \(note.blindLevelNumber)")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.goldAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.goldAccent.opacity(0.15))
                        .clipShape(Capsule())
                }

                if !note.blindsDisplay.isEmpty {
                    Text(note.blindsDisplay)
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)
                }

                Spacer()

                if let stack = note.stackBefore {
                    Text(formatChips(stack))
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)
                }
            }

            // Body: description text
            Text(note.descriptionText)
                .font(PokerTypography.chatBody)
                .foregroundColor(.textPrimary)
                .multilineTextAlignment(.leading)
        }
        .padding(12)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.borderSubtle, lineWidth: 0.5)
        )
    }

    // MARK: - Add Note Button

    private var addNoteButton: some View {
        Button {
            noteText = ""
            showAddSheet = true
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                Text("Add Hand Note")
                    .font(PokerTypography.chipLabel)
            }
            .foregroundColor(.goldAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.goldAccent.opacity(0.15))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.goldAccent.opacity(0.3), lineWidth: 1))
        }
    }

    // MARK: - Add/Edit Sheet

    private func addEditSheet(isNew: Bool, existingNote: HandNote? = nil) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Context bar (when adding)
                if isNew {
                    contextBar
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }

                TextEditor(text: $noteText)
                    .font(PokerTypography.chatBody)
                    .foregroundColor(.textPrimary)
                    .scrollContentBackground(.hidden)
                    .background(Color.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.borderSubtle, lineWidth: 0.5)
                    )
                    .padding(16)

                Spacer()
            }
            .background(Color.backgroundPrimary)
            .navigationTitle(isNew ? "Add Hand Note" : "Edit Hand Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showAddSheet = false
                        editingNote = nil
                    }
                    .foregroundColor(.goldAccent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if isNew {
                            addNote()
                        } else if let note = existingNote {
                            updateNote(note)
                        }
                        HapticFeedback.success()
                        showAddSheet = false
                        editingNote = nil
                    }
                    .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .foregroundColor(.goldAccent)
                }
            }
            .onAppear {
                if let note = existingNote {
                    noteText = note.descriptionText
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Context Bar

    private var contextBar: some View {
        HStack(spacing: 12) {
            if let tournament {
                if let displayLevel = tournament.currentDisplayLevel {
                    Label("Level \(displayLevel)", systemImage: "chart.bar")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)
                }

                if let blinds = tournament.currentBlinds {
                    Text(blinds.blindsDisplay)
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)
                }

                if let stack = tournament.latestStack {
                    Text(stack.formattedChipCount)
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.goldAccent)
                }
            } else if let cashSession {
                if !cashSession.stakes.isEmpty {
                    Label(cashSession.stakes, systemImage: "dollarsign.circle")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)
                }

                if let stack = cashSession.latestStack {
                    Text("$\(stack.chipCount)")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.goldAccent)
                }
            }

            Spacer()
        }
        .padding(10)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 60)

            // Add button even in empty state
            addNoteButton
                .padding(.horizontal, 40)

            Spacer().frame(height: 20)

            Image(systemName: "note.text")
                .font(.system(size: 40))
                .foregroundColor(.textSecondary.opacity(0.5))

            Text("No hand notes yet")
                .font(PokerTypography.chatBody)
                .foregroundColor(.textSecondary)

            Text("Use chat: \"note: flopped a set of jacks\"")
                .font(PokerTypography.chatCaption)
                .foregroundColor(.textSecondary.opacity(0.7))

            Spacer()
        }
    }

    // MARK: - Helpers

    private func beginEditing(_ note: HandNote) {
        noteText = note.descriptionText
        editingNote = note
    }

    /// Route add through the appropriate manager
    private func addNote() {
        if cashSession != nil {
            cashSessionManager.addHandNote(text: noteText)
        } else {
            tournamentManager.addHandNote(text: noteText)
        }
    }

    /// Route update through the appropriate manager
    private func updateNote(_ note: HandNote) {
        if cashSession != nil {
            cashSessionManager.updateHandNote(note, text: noteText)
        } else {
            tournamentManager.updateHandNote(note, text: noteText)
        }
    }

    /// Route delete through the appropriate manager
    private func deleteNote(_ note: HandNote) {
        if cashSession != nil {
            cashSessionManager.deleteHandNote(note)
        } else {
            tournamentManager.deleteHandNote(note)
        }
    }

    private func formatChips(_ value: Int) -> String {
        if value >= 1_000_000 {
            let m = Double(value) / 1_000_000.0
            return String(format: "%.1fM", m)
        } else if value >= 1000 {
            let k = Double(value) / 1000.0
            if k == Double(Int(k)) {
                return "\(Int(k))k"
            }
            return String(format: "%.1fk", k)
        }
        return "\(value)"
    }
}

#Preview {
    HandNotesPane(tournament: Tournament(name: "Preview"))
        .environment(TournamentManager())
        .environment(CashSessionManager())
        .background(Color.backgroundPrimary)
}
