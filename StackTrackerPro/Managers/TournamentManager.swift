import Foundation
import SwiftData
import Observation

@MainActor @Observable
final class TournamentManager {
    var activeTournament: Tournament?
    var modelContext: ModelContext?

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
            tournament.stackEntries.append(entry)
        } else {
            let entry = StackEntry(
                chipCount: tournament.startingChips,
                source: .initial
            )
            tournament.stackEntries.append(entry)
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

    func completeTournament(position: Int? = nil, payout: Int? = nil) {
        guard let tournament = activeTournament else { return }
        tournament.status = .completed
        tournament.finishPosition = position
        tournament.payout = payout
        save()
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
        tournament.stackEntries.append(entry)
        save()
    }

    func updateBlinds(levelNumber: Int? = nil, sb: Int? = nil, bb: Int? = nil, ante: Int? = nil) {
        guard let tournament = activeTournament else { return }

        if let levelNumber {
            tournament.currentBlindLevelNumber = levelNumber

            // If we have this level in blind structure, update from it
            if tournament.blindLevels.contains(where: { $0.levelNumber == levelNumber }) {
                // Level exists in structure, use its values (unless overridden)
                if sb == nil && bb == nil {
                    return // Values come from the structure
                }
            }
        }

        // If blinds provided but no matching level in structure, create/update
        if let sb, let bb {
            let levelNum = levelNumber ?? tournament.currentBlindLevelNumber
            if let existing = tournament.blindLevels.first(where: { $0.levelNumber == levelNum }) {
                existing.smallBlind = sb
                existing.bigBlind = bb
                if let ante { existing.ante = ante }
            } else {
                let newLevel = BlindLevel(
                    levelNumber: levelNum,
                    smallBlind: sb,
                    bigBlind: bb,
                    ante: ante ?? 0
                )
                tournament.blindLevels.append(newLevel)
            }
            tournament.currentBlindLevelNumber = levelNum
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
        tournament.fieldSnapshots.append(snapshot)

        save()
    }

    func recordBounty() {
        guard let tournament = activeTournament else { return }
        tournament.bountiesCollected += 1

        let event = BountyEvent(
            amount: tournament.bountyAmount
        )
        tournament.bountyEvents.append(event)

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
        tournament.stackEntries.append(entry)

        save()
    }

    func recordHandNote(_ text: String) {
        guard let tournament = activeTournament else { return }
        let note = HandNote(
            descriptionText: text,
            stackBefore: tournament.latestStack?.chipCount,
            stackAfter: nil
        )
        tournament.handNotes.append(note)
        save()
    }

    // MARK: - Persistence

    private func save() {
        try? modelContext?.save()
    }
}
