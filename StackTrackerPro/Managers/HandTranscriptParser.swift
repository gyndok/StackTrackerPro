import Foundation

/// Table context injected into the parsing instructions so spoken numbers
/// resolve correctly ("seventy five" at 10K/25K blinds means 75,000 chips).
struct HandContext {
    let levelNumber: Int
    let smallBlind: Int
    let bigBlind: Int
    let ante: Int
    let heroStack: Int
    let heroCardCount: Int
}

#if canImport(FoundationModels)
import FoundationModels

// MARK: - Generable Output Structs

@Generable
struct SpokenVillain {
    @Guide(description: "Villain's seat: one of UTG, UTG+1, MP, LJ, HJ, CO, BTN, SB, BB. Null if not stated.")
    var position: String?
    @Guide(description: "Relative stack: 'covers' if they cover the hero, 'same' if similar, 'shorter' if shorter. Null if not stated.")
    var relativeStack: String?
    @Guide(description: "Villain's approximate chip count if a number was stated.")
    var approxStack: Int?
    @Guide(description: "Villain's shown hole cards at showdown in canonical form like 'Th 9h'. Null if mucked or unknown.")
    var shownCards: String?
}

@Generable
struct SpokenAction {
    @Guide(description: "Who acted: 'hero' or a seat name (UTG, MP, CO, BTN, SB, BB...).")
    var actor: String?
    @Guide(description: "Street: preflop, flop, turn, or river.")
    var street: String?
    @Guide(description: "Action: fold, check, call, bet, or raise.")
    var action: String?
    @Guide(description: "Total chip amount the action is TO (a raise to 75,000 → 75000). Null for fold/check/call.")
    var amount: Int?
    @Guide(description: "True if the action was all-in (jam, shove, ship).")
    var isAllIn: Bool?
}

@Generable
struct ParsedHandDraft {
    @Guide(description: "Hero's seat: one of UTG, UTG+1, MP, LJ, HJ, CO, BTN, SB, BB.")
    var heroPosition: String?
    @Guide(description: "Hero's hole cards, canonical: exact like 'Kh Kd' when suits were spoken, else rank shorthand like 'KQs' or '99'.")
    var heroCards: String?
    @Guide(description: "Every opponent mentioned, one entry per distinct seat.")
    var villains: [SpokenVillain]
    @Guide(description: "Every action in strict chronological order, including hero's.")
    var actions: [SpokenAction]
    @Guide(description: "Flop cards, canonical like 'Jh 8h 4d'. Null if the hand ended preflop.")
    var flop: String?
    @Guide(description: "Turn card, canonical like '2c'. Null if not reached.")
    var turn: String?
    @Guide(description: "River card, canonical like '3s'. Null if not reached.")
    var river: String?
}

// MARK: - Hand Transcript Parser

final class HandTranscriptParser: @unchecked Sendable {
    static let shared = HandTranscriptParser()

    /// Guards the availability cache below. The class is @unchecked Sendable;
    /// soundness relies on every access going through `lock`.
    private let lock = NSLock()
    private var _isAvailable = false
    private var lastAvailabilityCheck: Date?

    /// Re-check model availability at most this often (the model may have
    /// finished downloading since the last check, or become unavailable).
    private let availabilityRecheckInterval: TimeInterval = 60

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

    /// Forces a fresh availability check on the next `isAvailable` read.
    private func forceAvailabilityRecheck() {
        lock.lock()
        defer { lock.unlock() }
        lastAvailabilityCheck = nil
    }

    func parse(transcript: String, context: HandContext) async throws -> ParsedHandDraft {
        guard isAvailable else {
            throw AIParserError.modelUnavailable
        }

        // A fresh session per transcript. `LanguageModelSession` is multi-turn
        // and retains a transcript, so reusing one across dictations would make
        // the model carry over and recompute values from earlier hands. Each
        // hand must be parsed in complete isolation.
        let session = LanguageModelSession(instructions: Self.instructions(for: context))

        do {
            let response = try await session.respond(
                to: transcript,
                generating: ParsedHandDraft.self
            )
            return response.content
        } catch {
            // Re-evaluate availability on the next parse instead of trusting
            // the cached value (the model may have become unavailable).
            forceAvailabilityRecheck()
            throw error
        }
    }

    static func instructions(for context: HandContext) -> String {
        makeInstructions(for: context)
    }
}

#else

// MARK: - Fallback when FoundationModels is not available

// Plain mirrors so VoiceHandMapper compiles without FoundationModels.
struct SpokenVillain {
    var position: String?
    var relativeStack: String?
    var approxStack: Int?
    var shownCards: String?
}

struct SpokenAction {
    var actor: String?
    var street: String?
    var action: String?
    var amount: Int?
    var isAllIn: Bool?
}

struct ParsedHandDraft {
    var heroPosition: String?
    var heroCards: String?
    var villains: [SpokenVillain] = []
    var actions: [SpokenAction] = []
    var flop: String?
    var turn: String?
    var river: String?
}

final class HandTranscriptParser: @unchecked Sendable {
    static let shared = HandTranscriptParser()

    private init() {}

    var isAvailable: Bool { false }

    var statusMessage: String {
        "AI parsing not available on this device"
    }

    func parse(transcript: String, context: HandContext) async throws -> ParsedHandDraft {
        throw AIParserError.modelUnavailable
    }

    static func instructions(for context: HandContext) -> String {
        makeInstructions(for: context)
    }
}

#endif

// MARK: - Instructions (pure, deterministic, testable outside canImport)

private func makeInstructions(for context: HandContext) -> String {
    // Pinned locale so number grouping is always comma-style ("10,000")
    // regardless of the device locale — the prompt (and its deterministic
    // test) must not change with the environment.
    let style = IntegerFormatStyle<Int>.number.locale(Locale(identifier: "en_US"))
    let hasBlinds = context.bigBlind > 0

    // Cash-game / no-context hands carry no meaningful level or blinds; asserting
    // "blinds are 0/0" would mislead the model (and there's nothing to scale
    // spoken numbers against), so omit both the blinds sentence and the
    // blinds-scaling guidance entirely in that case.
    var contextSentences = "Table context for this hand:"
    if hasBlinds {
        let blinds = "\(context.smallBlind.formatted(style))/\(context.bigBlind.formatted(style))"
        contextSentences += " Level \(context.levelNumber), blinds are \(blinds) "
            + "with a \(context.ante.formatted(style)) ante."
    }
    if context.heroStack > 0 {
        contextSentences += " Hero's stack is \(context.heroStack.formatted(style))."
    }
    contextSentences += " Hero was dealt \(context.heroCardCount) hole card(s)."

    var paragraphs: [String] = []
    paragraphs.append("""
        Parse ONLY the transcript provided into a structured poker hand. Never \
        invent actions, villains, cards, or streets that were not stated — if a \
        value is not explicitly said, leave it null. Treat the transcript in \
        isolation.
        """)
    paragraphs.append(contextSentences)
    paragraphs.append("""
        Cards must be written in canonical two-character form: rank followed by \
        suit letter (s/h/d/c), space-separated for multiple cards — for example a \
        flop of jack of hearts, eight of hearts, four of diamonds is written \
        "Jh 8h 4d".
        """)
    if hasBlinds {
        paragraphs.append("""
            Spoken numbers are chip amounts scaled to the stakes above, not literal \
            decimals: "seventy five" or "seventy five K" near these stakes means \
            75,000; "five one" means 51,000 when it is a bet or raise amount, not 5.1. \
            Use judgement based on the blinds and stacks given above to disambiguate \
            shorthand chip counts.
            """)
    }
    paragraphs.append("""
        "Jam", "shove", and "ship" all mean the action was all-in. A phrase like \
        "he had me covered" or "he covered me" means that villain's relativeStack \
        is 'covers'.
        """)
    paragraphs.append("""
        Identifying the hero: the hero is the narrator speaking in first person \
        ("I", "me", "my"). heroPosition is the seat the hero explicitly says they \
        were in (e.g. "I had kings on the button" → heroPosition is BTN, "in the \
        cutoff" → CO). heroCards are the cards the narrator says they personally \
        held (e.g. "I had kings, king of hearts king of diamonds" → "Kh Kd"). Do \
        not confuse the hero's own seat or cards with any villain's seat or \
        cards mentioned elsewhere in the transcript — a seat name like "UTG" used \
        to describe an opponent's action is that opponent's position, never the \
        hero's, even if it appears right after the hero's own sentence.
        """)
    paragraphs.append("""
        Worked disambiguation example: in "I had kings on the button, king of \
        hearts king of diamonds. UTG covered me and raised to seventy five \
        thousand", the hero's position is BTN and heroCards is "Kh Kd" — "UTG" \
        here names the opponent who acted, not the hero, even though the \
        sentence also contains the word "me".
        """)
    return paragraphs.joined(separator: "\n\n")
}
