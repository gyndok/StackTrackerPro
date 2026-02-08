import SwiftUI

struct LiveStackFlexView: View {
    let tournament: Tournament
    let size: ShareCardSize

    private var isSquare: Bool { size == .square }

    // MARK: - Computed Data

    private var latestChipCount: Int {
        tournament.latestStack?.chipCount ?? tournament.startingChips
    }

    private var bbCount: Double {
        tournament.latestStack?.bbCount ?? 0
    }

    private var bbZone: BBZone {
        BBZone.from(bbCount: bbCount)
    }

    private var percentOfAverage: String? {
        guard tournament.averageStack > 0 else { return nil }
        let pct = (Double(latestChipCount) / Double(tournament.averageStack)) * 100
        return String(format: "%.0f%% of average", pct)
    }

    private var blindLevelText: String {
        guard let blinds = tournament.currentBlinds else { return "" }
        let level = tournament.currentDisplayLevel ?? tournament.currentBlindLevelNumber
        var text = "Level \(level) \u{2014} \(blinds.smallBlind)/\(blinds.bigBlind)"
        if blinds.ante > 0 {
            text += " ante \(blinds.ante)"
        }
        return text
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            ShareCardBackground()

            VStack(spacing: isSquare ? 10 : 14) {
                ShareCardHeader(
                    eventName: tournament.name,
                    venueName: tournament.venueName
                )

                GoldDivider()

                // Hero stack
                VStack(spacing: 4) {
                    Text(latestChipCount.formatted())
                        .font(PokerTypography.shareHero)
                        .foregroundColor(.textPrimary)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(bbZone.color)
                            .frame(width: 8, height: 8)
                        Text(String(format: "%.1f BB", bbCount))
                            .font(PokerTypography.shareValue)
                            .foregroundColor(.textSecondary)
                    }
                }

                if let pctText = percentOfAverage {
                    Text(pctText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.textSecondary)
                }

                GoldDivider()

                // Mini chart
                MiniStackChartView(
                    entries: tournament.sortedStackEntries,
                    height: isSquare ? 80 : 100
                )

                // Blind level
                if !blindLevelText.isEmpty {
                    Text(blindLevelText)
                        .font(PokerTypography.shareValue)
                        .foregroundColor(.goldAccent)
                }

                GoldDivider()

                ShareCardFooter()
            }
            .padding(16)
        }
    }
}
