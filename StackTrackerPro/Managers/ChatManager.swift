import Foundation
import SwiftData
import Observation
import os

@MainActor @Observable
final class ChatManager {
    var isProcessing = false

    @ObservationIgnored
    private let logger = Logger(subsystem: "com.gyndok.stacktrackerpro", category: "ChatManager")

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

    // MARK: - Stub Shorthand

    /// "stub KQs" or ". KQs" → normalized cards; nil when not a stub command.
    nonisolated static func stubShorthand(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let payload: String
        if lower.hasPrefix("stub ") {
            payload = String(trimmed.dropFirst(5))
        } else if trimmed.hasPrefix(". ") {
            payload = String(trimmed.dropFirst(2))
        } else {
            return nil
        }
        return HoleCardShorthand.normalize(payload)
    }

    // MARK: - Core Flow

    func processUserMessage(text: String) async {
        guard let tournament = tournamentManager.activeTournament else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isProcessing = true
        defer { isProcessing = false }

        // 1. Save user message
        let userMessage = ChatMessage(sender: .user, text: text)
        tournament.chatMessages?.append(userMessage)

        // Stub shorthand: "stub KQs" / ". KQs" — no parse, no sheet, one-line ack.
        // Completed tournaments are read-only: fall through to normal parsing,
        // where applyEntities' guard keeps the message inert.
        if tournament.status != .completed, let cards = Self.stubShorthand(from: text) {
            let stub = tournamentManager.createHandStub(holeCards: cards, origin: .manual)
            var ack = "Stub saved: \(HoleCardShorthand.display(cards))"
            if let stub {
                var ctx: [String] = []
                if stub.levelNumber > 0 { ctx.append("at L\(stub.levelNumber)") }
                if stub.heroStackBefore > 0 { ctx.append("stack \(stub.heroStackBefore.formatted())") }
                if !ctx.isEmpty { ack += " " + ctx.joined(separator: ", ") }
            }
            ack += "."
            tournament.chatMessages?.append(ChatMessage(sender: .ai, text: ack))
            saveContext()
            HapticFeedback.impact(.light)
            return
        }

        // 2. Parse (AI with regex fallback)
        let entities = await parseMessage(text)

        // 3. Apply entities to tournament state
        applyEntities(entities, to: tournament)

        // 4. Generate response
        let responseText = responseEngine.generateResponse(entities: entities, tournament: tournament)

        // 5. Save AI response
        let aiMessage = ChatMessage(sender: .ai, text: responseText)
        tournament.chatMessages?.append(aiMessage)

        saveContext()
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
            // Apply directly via the manager API — text parsing ignores bare
            // numbers below 1000, which made this a no-op for short stacks.
            guard tournament.status != .completed, let last = tournament.latestStack else { break }

            let userMessage = ChatMessage(sender: .user, text: "Same stack: \(last.chipCount)")
            tournament.chatMessages?.append(userMessage)

            tournamentManager.updateStack(chipCount: last.chipCount)

            var entities = ParsedEntities()
            entities.chipCount = last.chipCount
            let responseText = responseEngine.generateResponse(entities: entities, tournament: tournament)
            let aiMessage = ChatMessage(sender: .ai, text: responseText)
            tournament.chatMessages?.append(aiMessage)

            saveContext()
            HapticFeedback.impact(.light)
        case .stats:
            let summary = responseEngine.sessionSummaryResponse(tournament: tournament)
            let aiMessage = ChatMessage(sender: .ai, text: summary)
            tournament.chatMessages?.append(aiMessage)
            saveContext()
        case .share:
            // Handled in ActiveSessionView (needs UI state for sheet presentation)
            break
        }
    }

    // MARK: - Persistence

    private func saveContext() {
        do {
            try tournamentManager.modelContext?.save()
        } catch {
            logger.error("Failed to save chat changes: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Parsing

    private func parseMessage(_ text: String) async -> ParsedEntities {
        // Try AI first, fall back to regex. Sanitize at the boundary so a bad
        // extraction (especially a hallucinated value from the AI model) can
        // never write garbage into the live session, and so the generated
        // response is built from the same clean values.
        if aiParser.isAvailable {
            do {
                return try await aiParser.parse(text).sanitized()
            } catch {
                // Fall through to regex
            }
        }

        return regexParser.parse(text).sanitized()
    }

    // MARK: - Apply Entities

    private func applyEntities(_ entities: ParsedEntities, to tournament: Tournament) {
        // Completed tournaments are read-only — never mutate state from chat.
        guard tournament.status != .completed else { return }

        // Defense in depth (mirrors RegexPokerParser and covers AI-parser
        // results): a hand note is the entire entity. Suppress all other
        // extraction so "note: villain busted my aces" can't trigger an
        // elimination, bounty, rebuy, payout, blinds, or stack update.
        if let note = entities.handNote {
            tournamentManager.recordHandNote(note)
            return
        }

        // Update blinds first (so stack entry captures correct blind info)
        if entities.smallBlind != nil || entities.bigBlind != nil || entities.levelNumber != nil {
            tournamentManager.updateBlinds(
                levelNumber: entities.levelNumber,
                sb: entities.smallBlind,
                bb: entities.bigBlind,
                ante: entities.ante,
                isDisplayLevel: true
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
    case share = "Share"

    var icon: String {
        switch self {
        case .bounty: return "target"
        case .rebuy: return "arrow.counterclockwise"
        case .sameStack: return "equal.circle"
        case .stats: return "chart.bar"
        case .share: return "square.and.arrow.up"
        }
    }
}
