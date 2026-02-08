import SwiftUI

// MARK: - Scouting Report Data Model

struct ScoutingReport {
    let structureSpeed: StructureSpeed
    let startingBBs: Double
    let antesIntroducedLevel: Int?
    let criticalLevels: [CriticalLevel]
    let overlayAmount: Int
    let playersNeeded: Int
    let hasBounty: Bool
    let bountyPercentOfBuyIn: Double?
    let estimatedITMPlayers: Int
    let gameTypeNotes: [String]
    let approachBullets: [String]
}

enum StructureSpeed: String {
    case turbo = "Turbo"
    case standard = "Standard"
    case deep = "Deep Stack"

    var color: Color {
        switch self {
        case .turbo: return .chipRed
        case .standard: return .mZoneYellow
        case .deep: return .mZoneGreen
        }
    }
}

struct CriticalLevel {
    let levelNumber: Int
    let blindsDisplay: String
    let bbCount: Double
    let zone: String
    let zoneColor: Color
}

// MARK: - Scouting Report Engine

struct ScoutingReportEngine {

    static func generate(for tournament: Tournament) -> ScoutingReport {
        let sortedLevels = tournament.sortedBlindLevels.filter { !$0.isBreak }
        let startingBB = sortedLevels.first?.bigBlind ?? Int(tournament.startingChips > 0 ? 200 : 1)
        let startingBBs = startingBB > 0 ? Double(tournament.startingChips) / Double(startingBB) : 0

        let speed = classifySpeed(startingBBs: startingBBs)
        let antesLevel = findAntesLevel(levels: sortedLevels)
        let criticals = findCriticalLevels(levels: sortedLevels, startingChips: tournament.startingChips, displayMap: tournament.displayLevelNumbers)
        let overlayAmount = tournament.overlay
        let playersNeeded = tournament.playersNeededForGuarantee

        let hasBounty = tournament.bountyAmount > 0
        let bountyPercent: Double? = hasBounty && tournament.buyIn > 0
            ? Double(tournament.bountyAmount) / Double(tournament.buyIn) * 100
            : nil

        let itmPlayers: Int
        if tournament.fieldSize > 0 {
            itmPlayers = Int(ceil(Double(tournament.fieldSize) * tournament.payoutPercent / 100.0))
        } else {
            itmPlayers = 0
        }

        let gameNotes = gameTypeNotes(for: tournament.gameType)
        let bullets = buildApproachBullets(
            speed: speed,
            antesLevel: antesLevel,
            hasBounty: hasBounty,
            bountyPercent: bountyPercent,
            overlayAmount: overlayAmount,
            startingBBs: startingBBs
        )

        return ScoutingReport(
            structureSpeed: speed,
            startingBBs: startingBBs,
            antesIntroducedLevel: antesLevel,
            criticalLevels: criticals,
            overlayAmount: overlayAmount,
            playersNeeded: playersNeeded,
            hasBounty: hasBounty,
            bountyPercentOfBuyIn: bountyPercent,
            estimatedITMPlayers: itmPlayers,
            gameTypeNotes: gameNotes,
            approachBullets: bullets
        )
    }

    // MARK: - Private Helpers

    private static func classifySpeed(startingBBs: Double) -> StructureSpeed {
        if startingBBs >= 100 {
            return .deep
        } else if startingBBs >= 40 {
            return .standard
        } else {
            return .turbo
        }
    }

    private static func findAntesLevel(levels: [BlindLevel]) -> Int? {
        for level in levels where level.ante > 0 {
            return level.levelNumber
        }
        return nil
    }

    private static func findCriticalLevels(levels: [BlindLevel], startingChips: Int, displayMap: [Int: Int]) -> [CriticalLevel] {
        var criticals: [CriticalLevel] = []
        var foundYellow = false
        var foundOrange = false
        var foundRed = false

        for level in levels {
            guard level.bigBlind > 0 else { continue }
            let bbCount = Double(startingChips) / Double(level.bigBlind)

            if !foundYellow && bbCount < 30 {
                foundYellow = true
                let displayNum = displayMap[level.levelNumber] ?? level.levelNumber
                criticals.append(CriticalLevel(
                    levelNumber: displayNum,
                    blindsDisplay: level.blindsDisplay,
                    bbCount: bbCount,
                    zone: "Yellow Zone",
                    zoneColor: .mZoneYellow
                ))
            }

            if !foundOrange && bbCount < 15 {
                foundOrange = true
                let displayNum = displayMap[level.levelNumber] ?? level.levelNumber
                criticals.append(CriticalLevel(
                    levelNumber: displayNum,
                    blindsDisplay: level.blindsDisplay,
                    bbCount: bbCount,
                    zone: "Orange Zone",
                    zoneColor: .mZoneOrange
                ))
            }

            if !foundRed && bbCount < 8 {
                foundRed = true
                let displayNum = displayMap[level.levelNumber] ?? level.levelNumber
                criticals.append(CriticalLevel(
                    levelNumber: displayNum,
                    blindsDisplay: level.blindsDisplay,
                    bbCount: bbCount,
                    zone: "Red Zone",
                    zoneColor: .mZoneRed
                ))
            }

            if foundYellow && foundOrange && foundRed { break }
        }

        return criticals
    }

    private static func gameTypeNotes(for gameType: GameType) -> [String] {
        switch gameType {
        case .nlh:
            return [
                "Position is paramount — play tighter from early position",
                "3-bet bluff more as antes kick in to exploit dead money",
                "Identify short stacks at your table for re-steal targets"
            ]
        case .plo:
            return [
                "Play position-dependent — avoid bloated multiway pots OOP",
                "Nut advantage matters more than in NLH — draw to the nuts",
                "Bounty hunting is harder in PLO — focus on premium rundowns"
            ]
        case .mixed:
            return [
                "Adjust aggression by game — be tighter in stud rounds",
                "Pay attention to antes in stud games — they add up fast",
                "Look for weak players in less common games"
            ]
        }
    }

    private static func buildApproachBullets(
        speed: StructureSpeed,
        antesLevel: Int?,
        hasBounty: Bool,
        bountyPercent: Double?,
        overlayAmount: Int,
        startingBBs: Double
    ) -> [String] {
        var bullets: [String] = []

        switch speed {
        case .deep:
            bullets.append("Deep structure — play patient through early levels and accumulate.")
        case .standard:
            bullets.append("Standard structure — balance patience with controlled aggression.")
        case .turbo:
            bullets.append("Turbo structure — be aggressive early, you can't wait for premiums.")
        }

        if let level = antesLevel {
            bullets.append("Antes start at Level \(level) — widen your range and attack limpers.")
        }

        if hasBounty, let pct = bountyPercent {
            if pct >= 50 {
                bullets.append("Large bounty (\(Int(pct))% of buy-in) — adjust calling ranges wider against short stacks.")
            } else {
                bullets.append("Bounty in play — factor bounty equity into marginal all-in decisions.")
            }
        }

        if overlayAmount > 0 {
            bullets.append("$\(overlayAmount.formatted()) overlay expected — great value spot.")
        }

        return bullets
    }
}
