import Foundation
import SwiftData

enum StubOrigin: String, CaseIterable {
    case manual, swingDetected, breakDebrief
}

enum StubStatus: String, CaseIterable {
    case pending, enriched, dismissed
}

enum QuickResult: String, CaseIterable {
    case won = "Won", lost = "Lost", chopped = "Chopped"
}

enum QuickVillain: String, CaseIterable {
    case shorter = "vs shorter", covered = "vs covered"
}

/// A 5-second capture of a hand's existence: auto-filled session context plus
/// the hero's hole cards. Enriched into a full Hand later (Capture Screen).
@Model
final class HandStub {
    var createdAt: Date = Date.now
    var levelNumber: Int = 0
    var smallBlind: Int = 0
    var bigBlind: Int = 0
    var ante: Int = 0
    var heroStackBefore: Int = 0      // 0 = unknown
    var heroStackAfter: Int = 0       // 0 = unknown; filled by enrichment
    var playersRemaining: Int = 0
    /// "Ah Kd" (exact), "KQs"/"AKo"/"99" (suit-agnostic), "" = awaiting cards
    var holeCards: String = ""
    var quickResultRaw: String = ""
    var quickVillainRaw: String = ""
    var originRaw: String = StubOrigin.manual.rawValue
    var statusRaw: String = StubStatus.pending.rawValue

    var tournament: Tournament?
    @Relationship(inverse: \Hand.sourceStub)
    var enrichedHand: Hand?

    init(levelNumber: Int = 0, smallBlind: Int = 0, bigBlind: Int = 0, ante: Int = 0,
         heroStackBefore: Int = 0, playersRemaining: Int = 0,
         holeCards: String = "", origin: StubOrigin = .manual) {
        self.levelNumber = levelNumber
        self.smallBlind = smallBlind
        self.bigBlind = bigBlind
        self.ante = ante
        self.heroStackBefore = heroStackBefore
        self.playersRemaining = playersRemaining
        self.holeCards = holeCards
        self.originRaw = origin.rawValue
    }

    var origin: StubOrigin { StubOrigin(rawValue: originRaw) ?? .manual }
    var status: StubStatus { StubStatus(rawValue: statusRaw) ?? .pending }
    var quickResult: QuickResult? { QuickResult(rawValue: quickResultRaw) }
    var quickVillain: QuickVillain? { QuickVillain(rawValue: quickVillainRaw) }

    func setStatus(_ status: StubStatus) { statusRaw = status.rawValue }

    var blindsDisplay: String {
        guard bigBlind > 0 else { return "" }
        var s = "\(smallBlind.formatted())/\(bigBlind.formatted())"
        if ante > 0 { s += "(\(ante.formatted()))" }
        return s
    }

    /// One-line recap export form: "L21 — KQs — Won vs covered (unenriched)"
    var exportLine: String {
        var parts: [String] = []
        parts.append(levelNumber > 0 ? "L\(levelNumber)" : "—")
        parts.append(holeCards.isEmpty ? "cards unknown" : holeCards)
        var result = quickResult?.rawValue ?? ""
        if let v = quickVillain { result += result.isEmpty ? v.rawValue : " \(v.rawValue)" }
        if !result.isEmpty { parts.append(result) }
        return parts.joined(separator: " — ") + " (unenriched)"
    }
}
