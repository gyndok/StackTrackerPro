import SwiftUI
import Charts

struct AnalyticsDashboardView: View {
    let tournaments: [Tournament]

    // Chart scrubbing (session number under the touch point)
    @State private var scrubSession: Int?

    // MARK: - Computed Properties

    private var totalProfit: Int {
        tournaments.compactMap(\.profit).reduce(0, +)
    }

    private var totalInvestment: Int {
        tournaments.map(\.totalInvestment).reduce(0, +)
    }

    // Tournaments with a recorded result; nil-payout records are excluded
    // from ROI and win-rate so they don't read as $0 cashes or losses.
    private var resolvedTournaments: [Tournament] {
        tournaments.filter { $0.payout != nil }
    }

    private var totalReturn: Int {
        resolvedTournaments.compactMap { t -> Int? in
            guard let payout = t.payout else { return nil }
            return payout + t.bountyWinnings
        }.reduce(0, +)
    }

    private var overallROI: Double {
        let resolvedInvestment = resolvedTournaments.map(\.totalInvestment).reduce(0, +)
        guard resolvedInvestment > 0 else { return 0 }
        return Double(totalReturn - resolvedInvestment) / Double(resolvedInvestment) * 100
    }

    private var winRate: Double {
        let resolved = resolvedTournaments
        guard !resolved.isEmpty else { return 0 }
        let wins = resolved.filter { ($0.profit ?? 0) > 0 }.count
        return Double(wins) / Double(resolved.count) * 100
    }

    private var totalHoursPlayed: Double {
        tournaments.compactMap(\.duration).reduce(0, +) / 3600
    }

    private var profitTimeSeries: [(session: Int, date: Date, cumulative: Int)] {
        let sorted = tournaments
            .filter { $0.endDate != nil && $0.profit != nil }
            .sorted { ($0.endDate ?? .distantPast) < ($1.endDate ?? .distantPast) }

        var running = 0
        return sorted.enumerated().map { index, t in
            running += t.profit ?? 0
            return (session: index + 1, date: t.endDate ?? .distantPast, cumulative: running)
        }
    }

    /// ROI per buy-in bucket, computed from resolved (payout-entered)
    /// tournaments only — same basis as `overallROI`. Empty buckets are skipped.
    private var buyInRangeStats: [(label: String, sessions: Int, profit: Int, roi: Double)] {
        let buckets: [(label: String, lower: Int, upper: Int?)] = [
            ("Under $150", 0, 150),
            ("$150 – $500", 150, 500),
            ("$500 – $1.5k", 500, 1500),
            ("Over $1.5k", 1500, nil)
        ]

        return buckets.compactMap { bucket in
            let group = resolvedTournaments.filter { t in
                let investment = t.totalInvestment
                guard investment >= bucket.lower else { return false }
                if let upper = bucket.upper {
                    return investment < upper
                }
                return true
            }
            guard !group.isEmpty else { return nil }

            let invested = group.map(\.totalInvestment).reduce(0, +)
            let returned = group.reduce(0) { $0 + (($1.payout ?? 0) + $1.bountyWinnings) }
            let profit = group.compactMap(\.profit).reduce(0, +)
            let roi = invested > 0 ? Double(returned - invested) / Double(invested) * 100 : 0
            return (label: bucket.label, sessions: group.count, profit: profit, roi: roi)
        }
    }

    private var gameTypeStats: [(type: GameType, sessions: Int, profit: Int, winRate: Double)] {
        let grouped = Dictionary(grouping: tournaments) { $0.gameType }
        return GameType.allCases.compactMap { type -> (GameType, Int, Int, Double)? in
            guard let group = grouped[type], !group.isEmpty else { return nil }
            let sessions = group.count
            let profit = group.compactMap(\.profit).reduce(0, +)
            let resolved = group.filter { $0.profit != nil }
            let wins = resolved.filter { ($0.profit ?? 0) > 0 }.count
            let wr = resolved.isEmpty ? 0 : Double(wins) / Double(resolved.count) * 100
            return (type, sessions, profit, wr)
        }
        .sorted { $0.2 > $1.2 }
    }

    private var venueStats: [(venue: String, sessions: Int, profit: Int, winRate: Double)] {
        let grouped = Dictionary(grouping: tournaments.filter { $0.venueName != nil }) { $0.venueName! }
        return grouped.compactMap { venue, group -> (String, Int, Int, Double)? in
            guard group.count >= 2 else { return nil }
            let sessions = group.count
            let profit = group.compactMap(\.profit).reduce(0, +)
            let resolved = group.filter { $0.profit != nil }
            let wins = resolved.filter { ($0.profit ?? 0) > 0 }.count
            let wr = resolved.isEmpty ? 0 : Double(wins) / Double(resolved.count) * 100
            return (venue, sessions, profit, wr)
        }
        .sorted { $0.2 > $1.2 }
    }

    private var biggestWin: Int {
        tournaments.compactMap(\.profit).max() ?? 0
    }

    private var biggestLoss: Int {
        tournaments.compactMap(\.profit).min() ?? 0
    }

    private var avgBuyIn: Int {
        guard !tournaments.isEmpty else { return 0 }
        return tournaments.map(\.totalInvestment).reduce(0, +) / tournaments.count
    }

    private var avgFieldSize: Int {
        let withField = tournaments.filter { $0.fieldSize > 0 }
        guard !withField.isEmpty else { return 0 }
        return withField.map(\.fieldSize).reduce(0, +) / withField.count
    }

    private var itmRate: Double {
        guard !tournaments.isEmpty else { return 0 }
        let itm = tournaments.filter { ($0.payout ?? 0) > 0 }.count
        return Double(itm) / Double(tournaments.count) * 100
    }

    private var avgFinish: Double {
        let withFinish = tournaments.compactMap(\.finishPosition)
        guard !withFinish.isEmpty else { return 0 }
        return Double(withFinish.reduce(0, +)) / Double(withFinish.count)
    }

    private var currentStreak: String {
        let sorted = tournaments
            .filter { $0.endDate != nil && $0.profit != nil }
            .sorted { ($0.endDate ?? .distantPast) > ($1.endDate ?? .distantPast) }

        guard let first = sorted.first else { return "0" }
        let isWin = (first.profit ?? 0) > 0
        var count = 0
        for t in sorted {
            let tWin = (t.profit ?? 0) > 0
            if tWin == isWin {
                count += 1
            } else {
                break
            }
        }
        return "\(count)\(isWin ? "W" : "L")"
    }

    private var totalBounties: Int {
        tournaments.map(\.bountiesCollected).reduce(0, +)
    }

    private var avgDuration: String {
        let durations = tournaments.compactMap(\.duration)
        guard !durations.isEmpty else { return "0m" }
        let avg = durations.reduce(0, +) / Double(durations.count)
        let hours = Int(avg) / 3600
        let minutes = (Int(avg) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter
    }()

    private var monthlyStats: [(month: String, profit: Int, sessions: Int)] {
        let calendar = Calendar.current
        let formatter = Self.monthFormatter

        let grouped = Dictionary(grouping: tournaments.filter { $0.endDate != nil }) { t -> String in
            let components = calendar.dateComponents([.year, .month], from: t.endDate!)
            let date = calendar.date(from: components) ?? t.endDate!
            return formatter.string(from: date)
        }

        // Sort by actual date (most recent first)
        let sortedKeys = grouped.keys.sorted { a, b in
            guard let dateA = formatter.date(from: a), let dateB = formatter.date(from: b) else { return false }
            return dateA > dateB
        }

        return sortedKeys.map { key in
            let group = grouped[key]!
            let profit = group.compactMap(\.profit).reduce(0, +)
            return (month: key, profit: profit, sessions: group.count)
        }
    }

    // MARK: - Body

    var body: some View {
        if tournaments.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 16) {
                    summaryCards
                    profitChart
                    roiByBuyInSection
                    gameTypeBreakdown
                    venueBreakdown
                    keyStatsGrid
                    monthlyBreakdown
                }
                .padding(16)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 60))
                .foregroundColor(.goldAccent.opacity(0.5))

            Text("No Analytics Available")
                .font(.title2.weight(.semibold))
                .foregroundColor(.textPrimary)

            Text("Complete tournaments to see\nyour performance analytics")
                .font(PokerTypography.chatBody)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Section 1: Summary Cards

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
                title: "ROI",
                value: String(format: "%.1f%%", overallROI),
                color: overallROI >= 0 ? .mZoneGreen : .chipRed
            )
            summaryCard(
                title: "Win Rate",
                value: String(format: "%.0f%%", winRate),
                color: .goldAccent
            )
            summaryCard(
                title: "Hours Played",
                value: String(format: "%.1f", totalHoursPlayed),
                color: .goldAccent
            )
        }
    }

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

    // MARK: - Section 2: Profit Over Time Chart

    private var profitChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PROFIT OVER TIME")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.textSecondary)

            if profitTimeSeries.count >= 2 {
                Chart {
                    ForEach(profitTimeSeries, id: \.session) { point in
                        AreaMark(
                            x: .value("Session", point.session),
                            y: .value("Profit", point.cumulative)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.goldAccent.opacity(0.3), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Session", point.session),
                            y: .value("Profit", point.cumulative)
                        )
                        .foregroundStyle(Color.goldAccent)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .interpolationMethod(.catmullRom)
                    }

                    if let last = profitTimeSeries.last {
                        PointMark(
                            x: .value("Session", last.session),
                            y: .value("Profit", last.cumulative)
                        )
                        .foregroundStyle(Color.goldAccent)
                        .symbolSize(50)
                    }

                    RuleMark(y: .value("Zero", 0))
                        .foregroundStyle(Color.textSecondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))

                    if let scrub = scrubSession,
                       let point = profitTimeSeries.first(where: { $0.session == scrub }) {
                        RuleMark(x: .value("Session", point.session))
                            .foregroundStyle(Color.goldAccent.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1))

                        PointMark(
                            x: .value("Session", point.session),
                            y: .value("Profit", point.cumulative)
                        )
                        .foregroundStyle(Color.goldAccent)
                        .symbolSize(70)
                        .annotation(
                            position: .top,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            ChartScrubCallout(
                                title: point.date.formatted(date: .abbreviated, time: .omitted),
                                value: formatCurrency(point.cumulative),
                                valueColor: point.cumulative >= 0 ? .mZoneGreen : .chipRed
                            )
                        }
                    }
                }
                .frame(height: 200)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { drag in
                                        guard let plotFrame = proxy.plotFrame else { return }
                                        let x = drag.location.x - geo[plotFrame].origin.x
                                        if let session: Int = proxy.value(atX: x) {
                                            scrubSession = profitTimeSeries.min {
                                                abs($0.session - session) < abs($1.session - session)
                                            }?.session
                                        }
                                    }
                                    .onEnded { _ in scrubSession = nil }
                            )
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisValueLabel {
                            if let amount = value.as(Int.self) {
                                Text(formatCurrencyShort(amount))
                                    .font(.caption2)
                                    .foregroundColor(.textSecondary)
                            }
                        }
                        AxisGridLine()
                            .foregroundStyle(Color.borderSubtle)
                    }
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let session = value.as(Int.self) {
                                Text("#\(session)")
                                    .font(.caption2)
                                    .foregroundColor(.textSecondary)
                            }
                        }
                    }
                }
                .chartPlotStyle { plot in
                    plot
                        .background(Color.cardSurface.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            } else {
                chartPlaceholder("Need at least 2 sessions to show profit trend")
            }
        }
        .pokerCard()
    }

    // MARK: - Section 2b: ROI by Buy-in Range

    private var roiByBuyInSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ROI BY BUY-IN")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.textSecondary)

            if buyInRangeStats.isEmpty {
                HStack {
                    Spacer()
                    Text("Enter payouts to see ROI by buy-in")
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)
                    Spacer()
                }
                .padding(.vertical, 8)
            } else {
                ForEach(buyInRangeStats, id: \.label) { stat in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(stat.label)
                                .font(PokerTypography.chatBody)
                                .foregroundColor(.textPrimary)

                            HStack(spacing: 8) {
                                Text("\(stat.sessions) session\(stat.sessions == 1 ? "" : "s")")
                                    .font(PokerTypography.chatCaption)
                                    .foregroundColor(.textSecondary)

                                Text(String(format: "%.1f%% ROI", stat.roi))
                                    .font(PokerTypography.chatCaption)
                                    .foregroundColor(stat.roi >= 0 ? .mZoneGreen : .chipRed)
                            }
                        }

                        Spacer()

                        Text(formatCurrency(stat.profit))
                            .font(PokerTypography.statValue)
                            .foregroundColor(stat.profit >= 0 ? .mZoneGreen : .chipRed)
                    }
                    .padding(10)
                    .background(Color.cardSurface.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .pokerCard()
    }

    // MARK: - Section 3: Performance by Game Type

    private var gameTypeBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BY GAME TYPE")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.textSecondary)

            ForEach(gameTypeStats, id: \.type) { stat in
                performanceRow(
                    name: stat.type.label,
                    profit: stat.profit,
                    sessions: stat.sessions,
                    winRate: stat.winRate
                )
            }
        }
        .pokerCard()
    }

    // MARK: - Section 4: Performance by Venue

    private var venueBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BY VENUE")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.textSecondary)

            if venueStats.isEmpty {
                HStack {
                    Spacer()
                    Text("Play at least 2 sessions at a venue")
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)
                    Spacer()
                }
                .padding(.vertical, 8)
            } else {
                ForEach(venueStats, id: \.venue) { stat in
                    performanceRow(
                        name: stat.venue,
                        profit: stat.profit,
                        sessions: stat.sessions,
                        winRate: stat.winRate
                    )
                }
            }
        }
        .pokerCard()
    }

    // MARK: - Section 5: Key Stats Grid

    private var keyStatsGrid: some View {
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
                statCard(label: "Avg Buy-in", value: formatCurrency(avgBuyIn), color: .goldAccent)
                statCard(label: "Avg Field Size", value: avgFieldSize > 0 ? "\(avgFieldSize)" : "—", color: .goldAccent)
                statCard(label: "ITM Rate", value: String(format: "%.0f%%", itmRate), color: .goldAccent)
                statCard(label: "Avg Finish", value: avgFinish > 0 ? String(format: "%.1f", avgFinish) : "—", color: .goldAccent)
                statCard(label: "Total Sessions", value: "\(tournaments.count)", color: .goldAccent)
                statCard(label: "Current Streak", value: currentStreak, color: currentStreak.hasSuffix("W") ? .mZoneGreen : .chipRed)
                statCard(label: "Total Bounties", value: "\(totalBounties)", color: .goldAccent)
                statCard(label: "Avg Duration", value: avgDuration, color: .goldAccent)
            }
        }
        .pokerCard()
    }

    // MARK: - Section 6: Monthly Breakdown

    private var monthlyBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MONTHLY BREAKDOWN")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.textSecondary)

            ForEach(monthlyStats, id: \.month) { stat in
                HStack {
                    Text(stat.month)
                        .font(PokerTypography.chatBody)
                        .foregroundColor(.textPrimary)

                    Spacer()

                    Text("\(stat.sessions) session\(stat.sessions == 1 ? "" : "s")")
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)

                    Text(formatCurrency(stat.profit))
                        .font(PokerTypography.statValue)
                        .foregroundColor(stat.profit >= 0 ? .mZoneGreen : .chipRed)
                        .frame(width: 90, alignment: .trailing)
                }
                .padding(10)
                .background(Color.cardSurface.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .pokerCard()
    }

    // MARK: - Reusable Components

    private func performanceRow(name: String, profit: Int, sessions: Int, winRate: Double) -> some View {
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

    private func chartPlaceholder(_ message: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.cardSurface.opacity(0.5))
                .frame(height: 200)

            VStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.title2)
                    .foregroundColor(.textSecondary.opacity(0.5))
                Text(message)
                    .font(PokerTypography.chatCaption)
                    .foregroundColor(.textSecondary)
            }
        }
    }

    // MARK: - Helpers

    private func formatCurrency(_ amount: Int) -> String {
        if amount < 0 {
            return "-$\(abs(amount))"
        }
        return "$\(amount)"
    }

    private func formatCurrencyShort(_ amount: Int) -> String {
        let absAmount = abs(amount)
        let sign = amount < 0 ? "-" : ""
        if absAmount >= 10_000 {
            return "\(sign)$\(Int((Double(absAmount) / 1000).rounded()))k"
        }
        if absAmount >= 1000 {
            let thousands = (Double(absAmount) / 100).rounded() / 10
            let formatted = thousands == thousands.rounded()
                ? "\(Int(thousands))"
                : String(format: "%.1f", thousands)
            return "\(sign)$\(formatted)k"
        }
        return "\(sign)$\(absAmount)"
    }
}

#Preview {
    AnalyticsDashboardView(tournaments: [])
        .background(Color.backgroundPrimary)
}
