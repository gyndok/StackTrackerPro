import SwiftUI
import Charts

// MARK: - ResultsAnalyticsView (Router)

struct ResultsAnalyticsView: View {
    let filter: ResultsFilter
    let tournaments: [Tournament]
    let cashSessions: [CashSession]

    var body: some View {
        switch filter {
        case .tournaments:
            AnalyticsDashboardView(tournaments: tournaments)
        case .cash:
            CashAnalyticsView(sessions: cashSessions)
        case .all:
            CombinedAnalyticsView(tournaments: tournaments, cashSessions: cashSessions)
        }
    }
}

// MARK: - CashAnalyticsView

struct CashAnalyticsView: View {
    let sessions: [CashSession]

    // MARK: - Computed Properties

    private var totalProfit: Int {
        sessions.compactMap(\.profit).reduce(0, +)
    }

    private var winRate: Double {
        guard !sessions.isEmpty else { return 0 }
        let wins = sessions.filter { ($0.profit ?? 0) > 0 }.count
        return Double(wins) / Double(sessions.count) * 100
    }

    private var avgHourly: Double {
        let rates = sessions.compactMap(\.hourlyRate)
        guard !rates.isEmpty else { return 0 }
        return rates.reduce(0, +) / Double(rates.count)
    }

    private var totalHoursPlayed: Double {
        sessions.compactMap(\.duration).reduce(0, +) / 3600
    }

    private var stakeStats: [(stakes: String, sessions: Int, winRate: Double, profit: Int)] {
        let grouped = Dictionary(grouping: sessions) { $0.stakes }
        return grouped.map { stakes, group in
            let count = group.count
            let profit = group.compactMap(\.profit).reduce(0, +)
            let wins = group.filter { ($0.profit ?? 0) > 0 }.count
            let wr = count > 0 ? Double(wins) / Double(count) * 100 : 0
            return (stakes: stakes.isEmpty ? "Unknown" : stakes, sessions: count, winRate: wr, profit: profit)
        }
        .sorted { $0.profit > $1.profit }
    }

    private var biggestWin: Int {
        sessions.compactMap(\.profit).max() ?? 0
    }

    private var biggestLoss: Int {
        sessions.compactMap(\.profit).min() ?? 0
    }

    private var avgSessionDuration: String {
        let durations = sessions.compactMap(\.duration)
        guard !durations.isEmpty else { return "0m" }
        let avg = durations.reduce(0, +) / Double(durations.count)
        let hours = Int(avg) / 3600
        let minutes = (Int(avg) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    // MARK: - Body

    var body: some View {
        if sessions.isEmpty {
            cashEmptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 16) {
                    summaryCards
                    byStakesSection
                    keyStatsSection
                }
                .padding(16)
            }
        }
    }

    // MARK: - Empty State

    private var cashEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 60))
                .foregroundColor(.goldAccent.opacity(0.5))

            Text("No Cash Analytics")
                .font(.title2.weight(.semibold))
                .foregroundColor(.textPrimary)

            Text("Complete cash sessions to see\nyour performance analytics")
                .font(PokerTypography.chatBody)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]

        return LazyVGrid(columns: columns, spacing: 12) {
            summaryCard(
                title: "Total Profit",
                value: formatCurrency(totalProfit),
                color: totalProfit >= 0 ? .mZoneGreen : .chipRed
            )
            summaryCard(
                title: "Win Rate",
                value: String(format: "%.0f%%", winRate),
                color: .goldAccent
            )
            summaryCard(
                title: "Avg Hourly",
                value: formatCurrency(Int(avgHourly)) + "/hr",
                color: avgHourly >= 0 ? .mZoneGreen : .chipRed
            )
            summaryCard(
                title: "Hours Played",
                value: String(format: "%.1f", totalHoursPlayed),
                color: .goldAccent
            )
        }
    }

    // MARK: - By Stakes

    private var byStakesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BY STAKES")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.textSecondary)

            if stakeStats.isEmpty {
                HStack {
                    Spacer()
                    Text("No stake data available")
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)
                    Spacer()
                }
                .padding(.vertical, 8)
            } else {
                ForEach(stakeStats, id: \.stakes) { stat in
                    performanceRow(
                        name: stat.stakes,
                        sessions: stat.sessions,
                        winRate: stat.winRate,
                        profit: stat.profit
                    )
                }
            }
        }
        .pokerCard()
    }

    // MARK: - Key Stats

    private var keyStatsSection: some View {
        let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]

        return VStack(alignment: .leading, spacing: 12) {
            Text("KEY STATS")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.textSecondary)

            LazyVGrid(columns: columns, spacing: 10) {
                statCard(label: "Biggest Win", value: formatCurrency(biggestWin), color: .mZoneGreen)
                statCard(label: "Biggest Loss", value: formatCurrency(biggestLoss), color: .chipRed)
                statCard(label: "Total Sessions", value: "\(sessions.count)", color: .goldAccent)
                statCard(label: "Avg Session", value: avgSessionDuration, color: .goldAccent)
            }
        }
        .pokerCard()
    }

    // MARK: - Reusable Components

    private func summaryCard(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(PokerTypography.heroStat)
                .foregroundColor(color)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(title)
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .pokerCard()
    }

    private func performanceRow(name: String, sessions: Int, winRate: Double, profit: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(PokerTypography.chatBody)
                    .foregroundColor(.textPrimary)

                HStack(spacing: 8) {
                    Text("\(sessions) session\(sessions == 1 ? "" : "s")")
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)

                    Text("\(String(format: "%.0f%%", winRate)) win rate")
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)
                }
            }

            Spacer()

            Text(formatCurrency(profit))
                .font(PokerTypography.statValue)
                .foregroundColor(profit >= 0 ? .mZoneGreen : .chipRed)
        }
        .padding(10)
        .background(Color.cardSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statCard(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(PokerTypography.statValue)
                .foregroundColor(color)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(PokerTypography.chatCaption)
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color.cardSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Helpers

    private func formatCurrency(_ amount: Int) -> String {
        if amount < 0 {
            return "-$\(abs(amount))"
        }
        return "$\(amount)"
    }
}

// MARK: - CombinedAnalyticsView

struct CombinedAnalyticsView: View {
    let tournaments: [Tournament]
    let cashSessions: [CashSession]

    // MARK: - Computed Properties

    private var totalProfit: Int {
        let tournamentProfit = tournaments.compactMap(\.profit).reduce(0, +)
        let cashProfit = cashSessions.compactMap(\.profit).reduce(0, +)
        return tournamentProfit + cashProfit
    }

    private var totalSessions: Int {
        tournaments.count + cashSessions.count
    }

    private var winRate: Double {
        guard totalSessions > 0 else { return 0 }
        let tournamentWins = tournaments.filter { ($0.profit ?? 0) > 0 }.count
        let cashWins = cashSessions.filter { ($0.profit ?? 0) > 0 }.count
        return Double(tournamentWins + cashWins) / Double(totalSessions) * 100
    }

    private var totalHoursPlayed: Double {
        let tournamentHours = tournaments.compactMap(\.duration).reduce(0, +)
        let cashHours = cashSessions.compactMap(\.duration).reduce(0, +)
        return (tournamentHours + cashHours) / 3600
    }

    private var tournamentProfit: Int {
        tournaments.compactMap(\.profit).reduce(0, +)
    }

    private var cashProfit: Int {
        cashSessions.compactMap(\.profit).reduce(0, +)
    }

    // MARK: - Body

    var body: some View {
        if totalSessions == 0 {
            combinedEmptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 16) {
                    summaryCards
                    byTypeSection
                }
                .padding(16)
            }
        }
    }

    // MARK: - Empty State

    private var combinedEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 60))
                .foregroundColor(.goldAccent.opacity(0.5))

            Text("No Analytics Available")
                .font(.title2.weight(.semibold))
                .foregroundColor(.textPrimary)

            Text("Complete sessions to see\nyour combined analytics")
                .font(PokerTypography.chatBody)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]

        return LazyVGrid(columns: columns, spacing: 12) {
            summaryCard(
                title: "Total Profit",
                value: formatCurrency(totalProfit),
                color: totalProfit >= 0 ? .mZoneGreen : .chipRed
            )
            summaryCard(
                title: "Win Rate",
                value: String(format: "%.0f%%", winRate),
                color: .goldAccent
            )
            summaryCard(
                title: "Total Sessions",
                value: "\(totalSessions)",
                color: .goldAccent
            )
            summaryCard(
                title: "Hours Played",
                value: String(format: "%.1f", totalHoursPlayed),
                color: .goldAccent
            )
        }
    }

    // MARK: - By Type Section

    private var byTypeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BY TYPE")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.textSecondary)

            typeRow(
                icon: "trophy.fill",
                iconColor: .goldAccent,
                name: "Tournaments",
                sessionCount: tournaments.count,
                profit: tournamentProfit
            )

            typeRow(
                icon: "dollarsign.circle.fill",
                iconColor: .chipBlue,
                name: "Cash Games",
                sessionCount: cashSessions.count,
                profit: cashProfit
            )
        }
        .pokerCard()
    }

    // MARK: - Reusable Components

    private func summaryCard(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(PokerTypography.heroStat)
                .foregroundColor(color)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(title)
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .pokerCard()
    }

    private func typeRow(icon: String, iconColor: Color, name: String, sessionCount: Int, profit: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(PokerTypography.chatBody)
                    .foregroundColor(.textPrimary)

                Text("\(sessionCount) session\(sessionCount == 1 ? "" : "s")")
                    .font(PokerTypography.chatCaption)
                    .foregroundColor(.textSecondary)
            }

            Spacer()

            Text(formatCurrency(profit))
                .font(PokerTypography.statValue)
                .foregroundColor(profit >= 0 ? .mZoneGreen : .chipRed)
        }
        .padding(10)
        .background(Color.cardSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Helpers

    private func formatCurrency(_ amount: Int) -> String {
        if amount < 0 {
            return "-$\(abs(amount))"
        }
        return "$\(amount)"
    }
}

// MARK: - Previews

#Preview("Cash Analytics") {
    CashAnalyticsView(sessions: [])
        .background(Color.backgroundPrimary)
}

#Preview("Combined Analytics") {
    CombinedAnalyticsView(tournaments: [], cashSessions: [])
        .background(Color.backgroundPrimary)
}
