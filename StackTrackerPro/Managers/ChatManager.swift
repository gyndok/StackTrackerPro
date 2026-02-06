import Foundation
import SwiftData
import Observation

@MainActor @Observable
final class ChatManager {
    var isProcessing = false

    private let tournamentManager: TournamentManager
    private let responseEngine = ResponseEngine.shared
    private let regexParser = RegexPokerParser.shared
    private let aiParser = AIPokerParser.shared

    var isAIAvailable: Bool {
        aiParser.isAvailable
    }

    var aiStatusMessage: String {
        aiParser.statusMessage
    }

    init(tournamentManager: TournamentManager) {
        self.tournamentManager = tournamentManager
    }

    // MARK: - Core Flow

    func processUserMessage(text: String) async {
        guard let tournament = tournamentManager.activeTournament else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isProcessing = true
        defer { isProcessing = false }

        // 1. Save user message
        let userMessage = ChatMessage(sender: .user, text: text)
        tournament.chatMessages.append(userMessage)

        // 2. Parse (AI with regex fallback)
        let entities = await parseMessage(text)

        // 3. Apply entities to tournament state
        applyEntities(entities, to: tournament)

        // 4. Generate response
        let responseText = responseEngine.generateResponse(entities: entities, tournament: tournament)

        // 5. Save AI response
        let aiMessage = ChatMessage(sender: .ai, text: responseText)
        tournament.chatMessages.append(aiMessage)

        try? tournamentManager.modelContext?.save()
        HapticFeedback.impact(.light)
    }

    func handleQuickAction(_ action: QuickAction) async {
        guard let tournament = tournamentManager.activeTournament else { return }

        switch action {
        case .bounty:
            await processUserMessage(text: "Got a bounty")
        case .rebuy:
            await processUserMessage(text: "I rebought")
        case .sameStack:
            if let last = tournament.latestStack {
                await processUserMessage(text: "\(last.chipCount)")
            }
        case .stats:
            let summary = responseEngine.sessionSummaryResponse(tournament: tournament)
            let aiMessage = ChatMessage(sender: .ai, text: summary)
            tournament.chatMessages.append(aiMessage)
            try? tournamentManager.modelContext?.save()
        }
    }

    // MARK: - Parsing

    private func parseMessage(_ text: String) async -> ParsedEntities {
        // Try AI first, fall back to regex
        if aiParser.isAvailable {
            do {
                return try await aiParser.parse(text)
            } catch {
                // Fall through to regex
            }
        }

        return regexParser.parse(text)
    }

    // MARK: - Apply Entities

    private func applyEntities(_ entities: ParsedEntities, to tournament: Tournament) {
        // Update blinds first (so stack entry captures correct blind info)
        if entities.smallBlind != nil || entities.bigBlind != nil || entities.levelNumber != nil {
            tournamentManager.updateBlinds(
                levelNumber: entities.levelNumber,
                sb: entities.smallBlind,
                bb: entities.bigBlind,
                ante: entities.ante
            )
        }

        // Update field
        if entities.totalEntries != nil || entities.playersRemaining != nil {
            tournamentManager.updateField(
                totalEntries: entities.totalEntries,
                playersRemaining: entities.playersRemaining
            )
        }

        // Record bounty
        if entities.bountyCollected {
            tournamentManager.recordBounty()
        }

        // Record rebuy
        if entities.tookRebuy {
            tournamentManager.recordRebuy()
        }

        // Update stack (after blinds so M-ratio is correct)
        if let chipCount = entities.chipCount {
            tournamentManager.updateStack(chipCount: chipCount)
        }

        // Hand note
        if let note = entities.handNote {
            tournamentManager.recordHandNote(note)
        }

        // Elimination
        if entities.isEliminated {
            tournamentManager.completeTournament(
                position: entities.finishPosition,
                payout: entities.payoutAmount
            )
        }
    }
}

// MARK: - Quick Actions

enum QuickAction: String, CaseIterable {
    case bounty = "Bounty"
    case rebuy = "Rebuy"
    case sameStack = "Same Stack"
    case stats = "Stats"

    var icon: String {
        switch self {
        case .bounty: return "target"
        case .rebuy: return "arrow.counterclockwise"
        case .sameStack: return "equal.circle"
        case .stats: return "chart.bar"
        }
    }
}
