import Foundation
import SwiftData
import Observation

@MainActor @Observable
final class TournamentManager {
    var activeTournament: Tournament?
    var modelContext: ModelContext?

    // Session recap state
    var showSessionRecap = false
    var showEndTournament = false
    private(set) var completedTournamentForRecap: Tournament?

    init() {}

    func setContext(_ context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - State Machine

    func startTournament(_ tournament: Tournament) {
        tournament.status = .active
        activeTournament = tournament

        // Record initial stack entry
        if let blinds = tournament.currentBlinds {
            let entry = StackEntry(
                chipCount: tournament.startingChips,
                blindLevelNumber: blinds.levelNumber,
                currentSB: blinds.smallBlind,
                currentBB: blinds.bigBlind,
                currentAnte: blinds.ante,
                source: .initial
            )
            tournament.stackEntries?.append(entry)
        } else {
            let entry = StackEntry(
                chipCount: tournament.startingChips,
                source: .initial
            )
            tournament.stackEntries?.append(entry)
        }

        save()
    }

    func pauseTournament() {
        activeTournament?.status = .paused
        save()
    }

    func resumeTournament() {
        activeTournament?.status = .active
        save()
    }

    func completeTournament(position: Int? = nil, payout: Int? = nil, endDate: Date = .now) {
        guard let tournament = activeTournament else { return }
        tournament.status = .completed
        tournament.finishPosition = position
        tournament.payout = payout
        tournament.endDate = endDate
        save()
        // Keep tournament alive for recap — do NOT clear activeTournament yet
        completedTournamentForRecap = tournament
        showSessionRecap = true
    }

    func showEndTournamentSheet() {
        showEndTournament = true
    }

    func dismissRecap() {
        showSessionRecap = false
        completedTournamentForRecap = nil
        activeTournament = nil
    }

    // MARK: - Updates

    func updateStack(chipCount: Int) {
        guard let tournament = activeTournament else { return }

        let blinds = tournament.currentBlinds
        let entry = StackEntry(
            chipCount: chipCount,
            blindLevelNumber: tournament.currentBlindLevelNumber,
            currentSB: blinds?.smallBlind ?? 0,
            currentBB: blinds?.bigBlind ?? 0,
            currentAnte: blinds?.ante ?? 0,
            source: .chat
        )
        tournament.stackEntries?.append(entry)
        save()
    }

    func updateBlinds(levelNumber: Int? = nil, sb: Int? = nil, bb: Int? = nil, ante: Int? = nil, isDisplayLevel: Bool = false) {
        guard let tournament = activeTournament else { return }

        if let levelNumber {
            // Convert display level to internal level if needed (e.g. user says "level 4" in chat)
            let mapped = isDisplayLevel ? (tournament.internalLevelNumbers[levelNumber] ?? levelNumber) : levelNumber
            let resolvedLevel = skipBreaks(from: mapped, in: tournament)
            tournament.currentBlindLevelNumber = resolvedLevel

            // If we have this level in blind structure, update from it
            if let existing = (tournament.blindLevels ?? []).first(where: { $0.levelNumber == resolvedLevel }) {
                // Level exists — apply overrides if provided, otherwise keep structure values
                if let sb { existing.smallBlind = sb }
                if let bb { existing.bigBlind = bb }
                if let ante { existing.ante = ante }
                save()
                return
            }

            // Level doesn't exist in structure — create it with provided or zero values
            if let sb, let bb {
                let newLevel = BlindLevel(
                    levelNumber: levelNumber,
                    smallBlind: sb,
                    bigBlind: bb,
                    ante: ante ?? 0
                )
                tournament.blindLevels?.append(newLevel)
            }
            save()
            return
        }

        // No level number provided — only blinds values
        guard let sb, let bb else {
            save()
            return
        }

        // Check if any existing level already matches these blinds
        if let matchingLevel = tournament.sortedBlindLevels.first(where: {
            $0.smallBlind == sb && $0.bigBlind == bb && !$0.isBreak
        }) {
            tournament.currentBlindLevelNumber = matchingLevel.levelNumber
            if let ante { matchingLevel.ante = ante }
        } else {
            // Create a new level at the next available level number
            let nextLevelNum = ((tournament.blindLevels ?? []).map(\.levelNumber).max() ?? 0) + 1
            let newLevel = BlindLevel(
                levelNumber: nextLevelNum,
                smallBlind: sb,
                bigBlind: bb,
                ante: ante ?? 0
            )
            tournament.blindLevels?.append(newLevel)
            tournament.currentBlindLevelNumber = nextLevelNum
        }

        save()
    }

    func updateField(totalEntries: Int? = nil, playersRemaining: Int? = nil) {
        guard let tournament = activeTournament else { return }

        if let totalEntries {
            tournament.fieldSize = totalEntries
        }
        if let playersRemaining {
            tournament.playersRemaining = playersRemaining
        }

        // Calculate average stack for snapshot
        let avgStack = tournament.averageStack

        let snapshot = FieldSnapshot(
            totalEntries: tournament.fieldSize,
            playersRemaining: tournament.playersRemaining,
            avgStack: avgStack > 0 ? avgStack : nil
        )
        tournament.fieldSnapshots?.append(snapshot)

        save()
    }

    func recordBounty() {
        guard let tournament = activeTournament else { return }
        tournament.bountiesCollected += 1

        let event = BountyEvent(
            amount: tournament.bountyAmount
        )
        tournament.bountyEvents?.append(event)

        save()
    }

    func recordRebuy() {
        guard let tournament = activeTournament else { return }
        tournament.rebuysUsed += 1

        // Reset stack to starting chips
        let blinds = tournament.currentBlinds
        let entry = StackEntry(
            chipCount: tournament.startingChips,
            blindLevelNumber: tournament.currentBlindLevelNumber,
            currentSB: blinds?.smallBlind ?? 0,
            currentBB: blinds?.bigBlind ?? 0,
            currentAnte: blinds?.ante ?? 0,
            source: .chat
        )
        tournament.stackEntries?.append(entry)

        save()
    }

    func recordHandNote(_ text: String) {
        guard let tournament = activeTournament else { return }
        let blinds = tournament.currentBlinds
        let note = HandNote(
            descriptionText: text,
            stackBefore: tournament.latestStack?.chipCount,
            stackAfter: nil,
            blindLevelNumber: tournament.currentBlindLevelNumber,
            blindsDisplay: blinds?.blindsDisplay ?? ""
        )
        tournament.handNotes?.append(note)
        save()
    }

    func addHandNote(text: String, stackBefore: Int? = nil) {
        guard let tournament = activeTournament else { return }
        let blinds = tournament.currentBlinds
        let note = HandNote(
            descriptionText: text,
            stackBefore: stackBefore ?? tournament.latestStack?.chipCount,
            stackAfter: nil,
            blindLevelNumber: tournament.currentBlindLevelNumber,
            blindsDisplay: blinds?.blindsDisplay ?? ""
        )
        tournament.handNotes?.append(note)
        save()
    }

    func updateHandNote(_ note: HandNote, text: String) {
        note.descriptionText = text
        save()
    }

    func deleteHandNote(_ note: HandNote) {
        guard let tournament = activeTournament else { return }
        tournament.handNotes?.removeAll { $0.persistentModelID == note.persistentModelID }
        modelContext?.delete(note)
        save()
    }

    func setCurrentLevel(_ levelNumber: Int) {
        guard let tournament = activeTournament else { return }
        tournament.currentBlindLevelNumber = skipBreaks(from: levelNumber, in: tournament)
        save()
    }

    /// If the target level is a break, advance to the next non-break level.
    private func skipBreaks(from levelNumber: Int, in tournament: Tournament) -> Int {
        let sorted = tournament.sortedBlindLevels
        guard let idx = sorted.firstIndex(where: { $0.levelNumber == levelNumber }),
              sorted[idx].isBreak else {
            return levelNumber
        }
        // Walk forward past consecutive breaks
        for i in (idx + 1)..<sorted.count {
            if !sorted[i].isBreak {
                return sorted[i].levelNumber
            }
        }
        return levelNumber
    }

    func addBlindLevel(smallBlind: Int, bigBlind: Int, ante: Int = 0, durationMinutes: Int = 30) {
        guard let tournament = activeTournament else { return }
        let nextNum = ((tournament.blindLevels ?? []).map(\.levelNumber).max() ?? 0) + 1
        let level = BlindLevel(
            levelNumber: nextNum,
            smallBlind: smallBlind,
            bigBlind: bigBlind,
            ante: ante,
            durationMinutes: durationMinutes
        )
        tournament.blindLevels?.append(level)
        save()
    }

    func deleteBlindLevel(_ level: BlindLevel) {
        guard let tournament = activeTournament else { return }
        tournament.blindLevels?.removeAll { $0.persistentModelID == level.persistentModelID }
        modelContext?.delete(level)
        save()
    }

    // MARK: - Persistence

    private func save() {
        try? modelContext?.save()
    }
}
