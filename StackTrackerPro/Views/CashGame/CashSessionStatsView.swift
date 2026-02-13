import SwiftUI

struct CashSessionStatsView: View {
    let session: CashSession

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    // MARK: - Computed

    private var currentPL: Int {
        guard let latest = session.latestStack else { return 0 }
        return latest.chipCount - session.buyInTotal
    }

    private var liveHourlyRate: Double {
        let elapsed = Date.now.timeIntervalSince(session.startTime)
        guard elapsed > 0 else { return 0 }
        return Double(currentPL) / (elapsed / 3600)
    }

    private var liveDuration: String {
        let elapsed = Date.now.timeIntervalSince(session.startTime)
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Hero P/L display
                heroPL

                // Stats grid
                LazyVGrid(columns: columns, spacing: 8) {
                    StatBlockView(
                        label: "Duration",
                        value: liveDuration
                    )

                    StatBlockView(
                        label: "Hourly Rate",
                        value: formatHourlyRate(liveHourlyRate),
                        valueColor: liveHourlyRate >= 0 ? .mZoneGreen : .chipRed
                    )

                    StatBlockView(
                        label: "Total Buy-in",
                        value: "$\(session.buyInTotal.formatted())"
                    )

                    StatBlockView(
                        label: "Current Stack",
                        value: session.latestStack != nil ? "$\(session.latestStack!.chipCount.formatted())" : "---"
                    )

                    StatBlockView(
                        label: "Stakes",
                        value: session.displayName
                    )

                    StatBlockView(
                        label: "Hand Notes",
                        value: "\(session.sortedHandNotes.count)"
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Hero P/L

    private var heroPL: some View {
        VStack(spacing: 4) {
            Text("Profit / Loss")
                .font(PokerTypography.chipLabel)
                .foregroundColor(.textSecondary)

            Text(currentPL >= 0 ? "+$\(currentPL.formatted())" : "-$\(abs(currentPL).formatted())")
                .font(PokerTypography.heroStat)
                .foregroundColor(currentPL >= 0 ? .mZoneGreen : .chipRed)
        }
        .frame(maxWidth: .infinity)
        .pokerCard()
    }

    // MARK: - Formatting

    private func formatHourlyRate(_ rate: Double) -> String {
        let formatted = String(format: "$%.0f/hr", abs(rate))
        return rate >= 0 ? "+\(formatted)" : "-\(formatted)"
    }
}

#Preview {
    CashSessionStatsView(session: {
        let s = CashSession(stakes: "1/2", gameType: .nlh, buyInTotal: 300, venueName: "Bellagio")
        return s
    }())
    .background(Color.backgroundPrimary)
}
