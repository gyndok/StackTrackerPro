import SwiftUI

struct SessionRecapCardView: View {
    let tournament: Tournament
    let size: ShareCardSize

    private var isSquare: Bool { size == .square }

    // MARK: - Computed Data

    private var positionText: String {
        guard let pos = tournament.finishPosition else { return "Completed" }
        return ordinalString(pos)
    }

    private var payoutText: String {
        guard let p = tournament.payout, p > 0 else { return "$0" }
        return "$\(p.formatted())"
    }

    private var roiPercent: Double? {
        guard tournament.totalInvestment > 0, let payout = tournament.payout else { return nil }
        let totalReturn = payout + (tournament.bountiesCollected * tournament.bountyAmount)
        return (Double(totalReturn - tournament.totalInvestment) / Double(tournament.totalInvestment)) * 100
    }

    private var duration: String {
        tournament.durationFormatted
    }

    private var peakStack: Int {
        tournament.sortedStackEntries.map(\.chipCount).max() ?? tournament.startingChips
    }

    private var bountyText: String? {
        guard tournament.bountiesCollected > 0, tournament.bountyAmount > 0 else { return nil }
        let total = tournament.bountiesCollected * tournament.bountyAmount
        return "\(tournament.bountiesCollected) bounties ($\(total.formatted()))"
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

                // Hero section
                VStack(spacing: 4) {
                    Text(positionText)
                        .font(PokerTypography.shareHero)
                        .foregroundColor(.goldAccent)

                    Text(payoutText)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.textPrimary)
                }

                // Metrics row
                HStack(spacing: 0) {
                    metricColumn(label: "Buy-in", value: "$\(tournament.totalInvestment.formatted())")
                    metricColumn(label: "ROI", value: roiPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                    metricColumn(label: "Duration", value: duration)
                    metricColumn(label: "Peak", value: formatChips(peakStack))
                }

                // Bounties
                if let bounty = bountyText {
                    Text(bounty)
                        .font(PokerTypography.shareValue)
                        .foregroundColor(.goldAccent)
                }

                GoldDivider()

                // Mini chart
                MiniStackChartView(
                    entries: tournament.sortedStackEntries,
                    height: isSquare ? 80 : 120
                )

                GoldDivider()

                ShareCardFooter()
            }
            .padding(16)
        }
    }

    // MARK: - Helpers

    private func metricColumn(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(PokerTypography.shareValue)
                .foregroundColor(.textPrimary)
            Text(label)
                .font(PokerTypography.shareLabel)
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatChips(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        } else if value >= 1000 {
            return String(format: "%.0fk", Double(value) / 1000)
        }
        return "\(value)"
    }

    private func ordinalString(_ n: Int) -> String {
        let suffix: String
        let ones = n % 10
        let tens = (n / 10) % 10
        if tens == 1 {
            suffix = "th"
        } else {
            switch ones {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix) Place"
    }
}
