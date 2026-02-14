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

    private func liveHourlyRate(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(session.startTime)
        guard elapsed > 0 else { return 0 }
        return Double(currentPL) / (elapsed / 3600)
    }

    private func liveDuration(at date: Date) -> String {
        let elapsed = date.timeIntervalSince(session.startTime)
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private var isCompleted: Bool {
        session.status == .completed
    }

    var body: some View {
        if isCompleted {
            statsContent(at: session.endTime ?? session.startTime)
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                statsContent(at: context.date)
            }
        }
    }

    private func statsContent(at date: Date) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                // Hero P/L display
                heroPL

                // Stats grid
                LazyVGrid(columns: columns, spacing: 8) {
                    StatBlockView(
                        label: "Duration",
                        value: liveDuration(at: date)
                    )

                    StatBlockView(
                        label: "Hourly Rate",
                        value: formatHourlyRate(liveHourlyRate(at: date)),
                        valueColor: liveHourlyRate(at: date) >= 0 ? .mZoneGreen : .chipRed
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
