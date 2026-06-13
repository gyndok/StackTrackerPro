import Foundation

#if canImport(FoundationModels)
import FoundationModels

// MARK: - Generable Output Struct

@Generable
struct ParsedPokerInput {
    @Guide(description: "The player's current chip count. k=thousands (18k=18000), M=millions. Only extract if the number represents a chip stack, not blinds or field size.")
    var chipCount: Int?

    @Guide(description: "Small blind amount from a blinds format like 500/1000 where 500 is the small blind.")
    var smallBlind: Int?

    @Guide(description: "Big blind amount from a blinds format like 500/1000 where 1000 is the big blind.")
    var bigBlind: Int?

    @Guide(description: "Ante amount if mentioned.")
    var ante: Int?

    @Guide(description: "Total number of entries/runners in the tournament.")
    var totalEntries: Int?

    @Guide(description: "Number of players remaining in the tournament.")
    var playersRemaining: Int?

    @Guide(description: "Final finish position if the player mentions busting or finishing.")
    var finishPosition: Int?

    @Guide(description: "Prize money amount if the player cashed.")
    var payoutAmount: Int?

    @Guide(description: "True if the player collected a bounty/knockout.")
    var bountyCollected: Bool?

    @Guide(description: "Current blind level number.")
    var levelNumber: Int?

    @Guide(description: "True if the player took a rebuy or re-entry.")
    var tookRebuy: Bool?

    @Guide(description: "True if the player was eliminated from the tournament.")
    var isEliminated: Bool?

    @Guide(description: "A hand description or notable play if the player describes a hand.")
    var handNote: String?
}

// MARK: - AI Poker Parser

final class AIPokerParser: @unchecked Sendable {
    static let shared = AIPokerParser()

    /// Guards all mutable state below. The class is @unchecked Sendable;
    /// soundness relies on every access to these properties going through
    /// `lock`.
    private let lock = NSLock()
    private var session: LanguageModelSession?
    private var parsesOnCurrentSession = 0
    private var _isAvailable = false
    private var lastAvailabilityCheck: Date?

    /// Re-check model availability at most this often (the model may have
    /// finished downloading since the last check, or become unavailable).
    private let availabilityRecheckInterval: TimeInterval = 60
    /// Proactively recycle the session after this many parses so the
    /// growing transcript never exceeds the model's context window.
    private let maxParsesPerSession = 20

    private init() {}

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastAvailabilityCheck,
           Date().timeIntervalSince(last) < availabilityRecheckInterval {
            return _isAvailable
        }
        lastAvailabilityCheck = Date()
        _isAvailable = (SystemLanguageModel.default.availability == .available)
        return _isAvailable
    }

    var statusMessage: String {
        let availability = SystemLanguageModel.default.availability
        switch availability {
        case .available:
            return "AI parsing active"
        case .unavailable(.deviceNotEligible):
            return "Device not supported (requires iPhone 16+)"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence not enabled"
        case .unavailable(.modelNotReady):
            return "AI model downloading..."
        default:
            return "AI parsing unavailable"
        }
    }

    /// Returns the current session, creating or recycling one as needed.
    private func currentSession() -> LanguageModelSession {
        lock.lock()
        defer { lock.unlock() }

        if parsesOnCurrentSession >= maxParsesPerSession {
            session = nil
            parsesOnCurrentSession = 0
        }

        if let session {
            parsesOnCurrentSession += 1
            return session
        }

        let instructions = """
            Extract poker tournament data. k=thousands, M=millions. \
            Blinds: SB/BB format (500/1000 means SB=500, BB=1000).
            """

        let newSession = LanguageModelSession(instructions: instructions)
        session = newSession
        parsesOnCurrentSession = 1
        return newSession
    }

    /// Discards the current session and forces a fresh availability check
    /// on the next `isAvailable` read.
    private func resetAfterFailure() {
        lock.lock()
        defer { lock.unlock() }
        session = nil
        parsesOnCurrentSession = 0
        lastAvailabilityCheck = nil
    }

    func parse(_ text: String) async throws -> ParsedEntities {
        guard isAvailable else {
            throw AIParserError.modelUnavailable
        }

        let session = currentSession()

        do {
            let response = try await session.respond(
                to: text,
                generating: ParsedPokerInput.self
            )
            return response.content.toEntities()
        } catch {
            // A grown transcript can exceed the context window, leaving the
            // session permanently broken (every subsequent parse would throw
            // and silently regress to regex). Recreate the session on the
            // next parse and re-evaluate availability instead of trusting
            // the cached value.
            resetAfterFailure()
            throw error
        }
    }
}

extension ParsedPokerInput {
    func toEntities() -> ParsedEntities {
        var entities = ParsedEntities()
        entities.chipCount = chipCount
        entities.smallBlind = smallBlind
        entities.bigBlind = bigBlind
        entities.ante = ante
        entities.totalEntries = totalEntries
        entities.playersRemaining = playersRemaining
        entities.finishPosition = finishPosition
        entities.payoutAmount = payoutAmount
        entities.bountyCollected = bountyCollected ?? false
        entities.levelNumber = levelNumber
        entities.tookRebuy = tookRebuy ?? false
        entities.isEliminated = isEliminated ?? false
        entities.handNote = handNote
        return entities
    }
}

#else

// MARK: - Fallback when FoundationModels is not available

final class AIPokerParser: @unchecked Sendable {
    static let shared = AIPokerParser()

    private init() {}

    var isAvailable: Bool { false }

    var statusMessage: String {
        "AI parsing not available on this device"
    }

    func parse(_ text: String) async throws -> ParsedEntities {
        throw AIParserError.modelUnavailable
    }
}

#endif

// MARK: - Errors

enum AIParserError: LocalizedError {
    case modelUnavailable
    case parsingFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "On-device AI model is not available"
        case .parsingFailed(let reason):
            return "Failed to parse message: \(reason)"
        }
    }
}
