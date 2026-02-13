import SwiftUI
import SwiftData
import Charts

// MARK: - Results Filter

enum ResultsFilter: String, CaseIterable {
    case all = "All"
    case cash = "Cash"
    case tournaments = "Tournaments"
}

// MARK: - View Mode

private enum ResultsViewMode: String, CaseIterable {
    case list = "List"
    case analytics = "Analytics"
}

// MARK: - Unified Session Item

private struct SessionItem: Identifiable {
    let id: String
    let date: Date
    let name: String
    let venue: String?
    let duration: String
    let detailLine: String
    let profit: Int
    let isTournament: Bool

    // Keep references for navigation
    let tournament: Tournament?
    let cashSession: CashSession?
}

// MARK: - ResultsView

struct ResultsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(TournamentManager.self) private var tournamentManager

    @Query(filter: #Predicate<Tournament> { $0.statusRaw == "completed" },
           sort: \Tournament.endDate, order: .reverse)
    private var completedTournaments: [Tournament]

    @Query(filter: #Predicate<CashSession> { $0.statusRaw == "completed" },
           sort: \CashSession.endTime, order: .reverse)
    private var completedCashSessions: [CashSession]

    @State private var selectedFilter: ResultsFilter = .all
    @State private var viewMode: ResultsViewMode = .list

    // MARK: - Computed Properties

    private var filteredTournaments: [Tournament] {
        switch selectedFilter {
        case .all, .tournaments:
            return completedTournaments
        case .cash:
            return []
        }
    }

    private var filteredCashSessions: [CashSession] {
        switch selectedFilter {
        case .all, .cash:
            return completedCashSessions
        case .tournaments:
            return []
        }
    }

    private var allSessions: [SessionItem] {
        var items: [SessionItem] = []

        if selectedFilter != .cash {
            for t in completedTournaments {
                let detail = buildTournamentDetail(t)
                items.append(SessionItem(
                    id: "t-\(t.persistentModelID.hashValue)",
                    date: t.endDate ?? t.startDate,
                    name: t.name,
                    venue: t.venueName,
                    duration: t.durationFormatted,
                    detailLine: detail,
                    profit: t.profit ?? 0,
                    isTournament: true,
                    tournament: t,
                    cashSession: nil
                ))
            }
        }

        if selectedFilter != .tournaments {
            for c in completedCashSessions {
                let detail = buildCashDetail(c)
                items.append(SessionItem(
                    id: "c-\(c.persistentModelID.hashValue)",
                    date: c.endTime ?? c.startTime,
                    name: c.displayName,
                    venue: c.venueName,
                    duration: c.durationFormatted,
                    detailLine: detail,
                    profit: c.profit ?? 0,
                    isTournament: false,
                    tournament: nil,
                    cashSession: c
                ))
            }
        }

        return items.sorted { $0.date > $1.date }
    }

    private var hasCompletedSessions: Bool {
        !completedTournaments.isEmpty || !completedCashSessions.isEmpty
    }

    private var filteredSessionCount: Int {
        allSessions.count
    }

    private var filteredWinRate: Double {
        let sessions = allSessions
        guard !sessions.isEmpty else { return 0 }
        let wins = sessions.filter { $0.profit > 0 }.count
        return Double(wins) / Double(sessions.count) * 100
    }

    private var filteredTotalProfit: Int {
        allSessions.map(\.profit).reduce(0, +)
    }

    private var cumulativePLData: [(session: Int, cumulative: Int)] {
        let sorted = allSessions.sorted { $0.date < $1.date }
        var running = 0
        return sorted.enumerated().map { index, item in
            running += item.profit
            return (session: index + 1, cumulative: running)
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if hasCompletedSessions {
                    filterBar
                }

                ZStack {
                    Color.backgroundPrimary.ignoresSafeArea()

                    if !hasCompletedSessions {
                        emptyState
                    } else if viewMode == .analytics {
                        ResultsAnalyticsView(
                            filter: selectedFilter,
                            tournaments: filteredTournaments,
                            cashSessions: filteredCashSessions
                        )
                    } else {
                        listContent
                    }
                }
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Results")
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(ResultsFilter.allCases, id: \.self) { filter in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedFilter = filter
                    }
                } label: {
                    Text(filter.rawValue)
                        .font(PokerTypography.chipLabel)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundColor(selectedFilter == filter ? .backgroundPrimary : .goldAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selectedFilter == filter ? Color.goldAccent : Color.goldAccent.opacity(0.15))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(Color.goldAccent.opacity(0.3), lineWidth: selectedFilter == filter ? 0 : 1)
                        )
                }
            }

            Spacer()

            Picker("View", selection: $viewMode) {
                ForEach(ResultsViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - List Content

    private var listContent: some View {
        List {
            Section {
                aggregateStatsHeader
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
            }

            if cumulativePLData.count >= 2 {
                Section {
                    cumulativePLChart
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                }
            }

            Section {
                ForEach(allSessions) { session in
                    if session.isTournament, let tournament = session.tournament {
                        NavigationLink {
                            ActiveSessionView(tournament: tournament)
                        } label: {
                            sessionRow(session)
                        }
                        .listRowBackground(Color.cardSurface)
                    } else if let cashSession = session.cashSession {
                        NavigationLink {
                            CashActiveSessionView(session: cashSession)
                        } label: {
                            sessionRow(session)
                        }
                        .listRowBackground(Color.cardSurface)
                    }
                }
                .onDelete(perform: deleteSessions)
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 60))
                .foregroundColor(.goldAccent.opacity(0.5))

            Text("No Completed Sessions")
                .font(.title2.weight(.semibold))
                .foregroundColor(.textPrimary)

            Text("Finished tournaments and cash sessions\nwill appear here with results and stats")
                .font(PokerTypography.chatBody)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    // MARK: - Aggregate Stats Header

    private var aggregateStatsHeader: some View {
        HStack(spacing: 0) {
            statColumn(value: "\(filteredSessionCount)", label: "Sessions")
            Divider().frame(height: 32).overlay(Color.borderSubtle)
            statColumn(
                value: String(format: "%.0f%%", filteredWinRate),
                label: "Win Rate"
            )
            Divider().frame(height: 32).overlay(Color.borderSubtle)
            statColumn(
                value: formatCurrency(filteredTotalProfit),
                label: "Profit",
                color: filteredTotalProfit >= 0 ? .mZoneGreen : .chipRed
            )
        }
        .padding(.vertical, 12)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.borderSubtle, lineWidth: 0.5)
        )
    }

    private func statColumn(value: String, label: String, color: Color = .textPrimary) -> some View {
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
    }

    // MARK: - Cumulative P/L Chart

    private var cumulativePLChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CUMULATIVE P/L")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.textSecondary)

            Chart {
                ForEach(cumulativePLData, id: \.session) { point in
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

                if let last = cumulativePLData.last {
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
            }
            .frame(height: 200)
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
        }
        .pokerCard()
    }

    // MARK: - Session Row

    private func sessionRow(_ session: SessionItem) -> some View {
        HStack(spacing: 12) {
            // Type icon
            Image(systemName: session.isTournament ? "trophy.fill" : "dollarsign.circle.fill")
                .font(.title3)
                .foregroundColor(session.isTournament ? .goldAccent : .chipBlue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.name)
                    .font(.headline)
                    .foregroundColor(.textPrimary)

                HStack(spacing: 8) {
                    if let venue = session.venue {
                        Text(venue)
                            .font(PokerTypography.chipLabel)
                            .foregroundColor(.textSecondary)
                    }

                    Text(session.date.formatted(date: .abbreviated, time: .omitted))
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)
                }

                HStack(spacing: 4) {
                    Text(session.duration)
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)

                    if !session.detailLine.isEmpty {
                        Text("·")
                            .foregroundColor(.textSecondary)
                        Text(session.detailLine)
                            .font(PokerTypography.chatCaption)
                            .foregroundColor(.textSecondary)
                    }
                }
            }

            Spacer()

            profitBadge(session.profit)
        }
        .padding(.vertical, 4)
    }

    private func profitBadge(_ profit: Int) -> some View {
        let isPositive = profit >= 0
        let color: Color = isPositive ? .mZoneGreen : .chipRed
        let text = isPositive ? "+\(formatCurrency(profit))" : formatCurrency(profit)

        return Text(text)
            .font(PokerTypography.chipLabel)
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    // MARK: - Detail Builders

    private func buildTournamentDetail(_ t: Tournament) -> String {
        var parts: [String] = []
        if let finish = t.finishPosition {
            let pos = ordinal(finish)
            if t.fieldSize > 0 {
                parts.append("\(pos) of \(t.fieldSize)")
            } else {
                parts.append(pos)
            }
        }
        parts.append("$\(t.totalInvestment) buy-in")
        return parts.joined(separator: " · ")
    }

    private func buildCashDetail(_ c: CashSession) -> String {
        var parts: [String] = []
        parts.append("$\(c.buyInTotal) buy-in")
        if let hourly = c.hourlyRate {
            let sign = hourly >= 0 ? "+" : ""
            parts.append("\(sign)\(formatCurrency(Int(hourly)))/hr")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Delete

    private func deleteSessions(at offsets: IndexSet) {
        let sessions = allSessions
        for index in offsets {
            let item = sessions[index]
            if let tournament = item.tournament {
                if tournamentManager.activeTournament?.persistentModelID == tournament.persistentModelID {
                    tournamentManager.activeTournament = nil
                }
                modelContext.delete(tournament)
            } else if let cashSession = item.cashSession {
                modelContext.delete(cashSession)
            }
        }
    }

    // MARK: - Formatting Helpers

    private func formatCurrency(_ amount: Int) -> String {
        if amount < 0 {
            return "-$\(abs(amount))"
        }
        return "$\(amount)"
    }

    private func formatCurrencyShort(_ amount: Int) -> String {
        let absAmount = abs(amount)
        let sign = amount < 0 ? "-" : ""
        if absAmount >= 1000 {
            return "\(sign)$\(absAmount / 1000)k"
        }
        return "\(sign)$\(absAmount)"
    }

    private func ordinal(_ n: Int) -> String {
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
        return "\(n)\(suffix)"
    }
}

// MARK: - Preview

#Preview {
    ResultsView()
        .modelContainer(for: [Tournament.self, CashSession.self], inMemory: true)
        .environment(TournamentManager())
        .environment(CashSessionManager())
        .environment(ChatManager(tournamentManager: TournamentManager()))
}
