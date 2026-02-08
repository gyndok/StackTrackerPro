import SwiftUI

struct BlindLevelsPane: View {
    @Environment(TournamentManager.self) private var tournamentManager
    let tournament: Tournament

    @State private var editingLevel: BlindLevel?
    @State private var showEditSheet = false

    // Edit fields
    @State private var editSB = ""
    @State private var editBB = ""
    @State private var editAnte = ""
    @State private var editDuration = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if tournament.sortedBlindLevels.isEmpty {
                        emptyState
                    } else {
                        ForEach(tournament.sortedBlindLevels, id: \.persistentModelID) { level in
                            blindRow(level)
                                .id(level.levelNumber)
                        }
                    }

                    // Add level button
                    addLevelButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onAppear {
                proxy.scrollTo(tournament.currentBlindLevelNumber, anchor: .center)
            }
            .onChange(of: tournament.currentBlindLevelNumber) { _, newLevel in
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(newLevel, anchor: .center)
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            blindEditSheet
        }
    }

    private func blindRow(_ level: BlindLevel) -> some View {
        let isCurrent = level.levelNumber == tournament.currentBlindLevelNumber

        return HStack {
            if level.isBreak {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.caption)
                    .foregroundColor(.textSecondary)
                Text(level.breakLabel ?? "Break")
                    .font(PokerTypography.chatBody)
                    .foregroundColor(.textSecondary)
            } else {
                Text("Lvl \(level.levelNumber)")
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(isCurrent ? .goldAccent : .textSecondary)
                    .frame(width: 48, alignment: .leading)

                Text(level.blindsDisplay)
                    .font(PokerTypography.statValue)
                    .foregroundColor(isCurrent ? .textPrimary : .textSecondary)

                Spacer()

                if level.durationMinutes > 0 {
                    Text("\(level.durationMinutes)m")
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)
                }

                // Edit pencil
                Button {
                    beginEditing(level)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundColor(.goldAccent.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            if isCurrent {
                Spacer()
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.caption2)
                    .foregroundColor(.goldAccent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Color.goldAccent.opacity(0.1) : Color.clear)
        )
        .overlay(
            isCurrent ?
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.goldAccent.opacity(0.3), lineWidth: 1)
                : nil
        )
        .contextMenu {
            Button(role: .destructive) {
                tournamentManager.deleteBlindLevel(level)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Add Level Button

    private var addLevelButton: some View {
        Button {
            let levels = tournament.sortedBlindLevels.filter { !$0.isBreak }
            let lastLevel = levels.last
            let nextSB = (lastLevel?.smallBlind ?? 25) * 2
            let nextBB = (lastLevel?.bigBlind ?? 50) * 2
            let nextAnte = lastLevel?.ante ?? 0
            tournamentManager.addBlindLevel(
                smallBlind: nextSB,
                bigBlind: nextBB,
                ante: nextAnte,
                durationMinutes: 30
            )
            HapticFeedback.impact(.light)
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                Text("Add Level")
                    .font(PokerTypography.chipLabel)
            }
            .foregroundColor(.goldAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Edit Sheet

    private func beginEditing(_ level: BlindLevel) {
        editingLevel = level
        editSB = "\(level.smallBlind)"
        editBB = "\(level.bigBlind)"
        editAnte = "\(level.ante)"
        editDuration = "\(level.durationMinutes)"
        showEditSheet = true
    }

    private var blindEditSheet: some View {
        NavigationStack {
            Form {
                Section("Blinds") {
                    HStack {
                        Text("Small Blind")
                        Spacer()
                        TextField("SB", text: $editSB)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    HStack {
                        Text("Big Blind")
                        Spacer()
                        TextField("BB", text: $editBB)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    HStack {
                        Text("Ante")
                        Spacer()
                        TextField("Ante", text: $editAnte)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                }

                Section("Duration") {
                    HStack {
                        Text("Minutes")
                        Spacer()
                        TextField("Min", text: $editDuration)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                }

                if let level = editingLevel {
                    Section {
                        Button {
                            tournamentManager.setCurrentLevel(level.levelNumber)
                            HapticFeedback.success()
                            showEditSheet = false
                        } label: {
                            HStack {
                                Image(systemName: "arrowtriangle.right.fill")
                                Text("Set as Current Level")
                            }
                            .foregroundColor(.goldAccent)
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                }
            }
            .navigationTitle("Edit Level \(editingLevel?.levelNumber ?? 0)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showEditSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveBlindEdit()
                    }
                    .disabled(Int(editSB) == nil || Int(editBB) == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func saveBlindEdit() {
        guard let level = editingLevel,
              let sb = Int(editSB),
              let bb = Int(editBB) else { return }

        level.smallBlind = sb
        level.bigBlind = bb
        level.ante = Int(editAnte) ?? 0
        level.durationMinutes = Int(editDuration) ?? 30

        // If this is the current level, trigger recalculation via save
        if level.levelNumber == tournament.currentBlindLevelNumber {
            tournamentManager.setCurrentLevel(level.levelNumber)
        }

        HapticFeedback.success()
        showEditSheet = false
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 60)

            Image(systemName: "list.number")
                .font(.system(size: 40))
                .foregroundColor(.textSecondary.opacity(0.5))

            Text("No blind structure set")
                .font(PokerTypography.chatBody)
                .foregroundColor(.textSecondary)

            Text("Levels will appear as you report blinds")
                .font(PokerTypography.chatCaption)
                .foregroundColor(.textSecondary.opacity(0.7))

            Spacer()
        }
    }
}

#Preview {
    BlindLevelsPane(tournament: {
        let t = Tournament(name: "Preview", startingChips: 20000)
        return t
    }())
    .environment(TournamentManager())
    .background(Color.backgroundPrimary)
}
