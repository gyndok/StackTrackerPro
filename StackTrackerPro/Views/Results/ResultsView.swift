import SwiftUI
import SwiftData
import Charts

// MARK: - Results Filter

enum ResultsFilter: String, CaseIterable {
    case all = "All"
    case cash = "Cash"
    case tournaments = "Tournaments"
}

// MARK: - Date Range Preset

enum DateRangePreset: String, CaseIterable {
    case allTime = "All Time"
    case thisWeek = "This Week"
    case thisMonth = "This Month"
    case last30Days = "Last 30 Days"
    case last90Days = "Last 90 Days"
    case thisYear = "This Year"
    case custom = "Custom"

    func dateRange() -> (start: Date, end: Date)? {
        let calendar = Calendar.current
        let now = Date.now
        switch self {
        case .allTime:
            return nil
        case .thisWeek:
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
            return (start, now)
        case .thisMonth:
            let start = calendar.dateInterval(of: .month, for: now)?.start ?? now
            return (start, now)
        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
            return (start, now)
        case .last90Days:
            let start = calendar.date(byAdding: .day, value: -90, to: now) ?? now
            return (start, now)
        case .thisYear:
            let start = calendar.dateInterval(of: .year, for: now)?.start ?? now
            return (start, now)
        case .custom:
            return nil
        }
    }
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
    let stakes: String?
    let gameTypeRaw: String
    let duration: String
    let detailLine: String
    /// nil when no result has been recorded (e.g. tournament with no payout entered)
    let profit: Int?
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

    // Advanced filters
    @State private var selectedGameTypeRaw: String?
    @State private var selectedStakes: String?
    @State private var selectedVenue: String?
    @State private var selectedDatePreset: DateRangePreset = .allTime
    @State private var customDateStart: Date = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var customDateEnd: Date = .now
    @State private var showFilterSheet = false

    // Chart scrubbing (session number under the touch point)
    @State private var plScrubSession: Int?

    // MARK: - Available Filter Options (derived from data)

    private var availableGameTypes: [(rawValue: String, label: String)] {
        var types = Set<String>()
        if selectedFilter != .cash {
            completedTournaments.forEach { types.insert($0.gameTypeRaw) }
        }
        if selectedFilter != .tournaments {
            completedCashSessions.forEach { types.insert($0.gameTypeRaw) }
        }
        return types.map { ($0, GameType.label(for: $0)) }.sorted { $0.label < $1.label }
    }

    private var availableStakes: [String] {
        guard selectedFilter != .tournaments else { return [] }
        let stakes = Set(completedCashSessions.map(\.stakes)).filter { !$0.isEmpty }
        return stakes.sorted()
    }

    private var availableVenues: [String] {
        var venues = Set<String>()
        if selectedFilter != .cash {
            completedTournaments.compactMap(\.venueName).forEach { venues.insert($0) }
        }
        if selectedFilter != .tournaments {
            completedCashSessions.compactMap(\.venueName).forEach { venues.insert($0) }
        }
        return venues.sorted()
    }

    private var hasActiveFilters: Bool {
        selectedGameTypeRaw != nil || selectedStakes != nil || selectedVenue != nil || selectedDatePreset != .allTime
    }

    private var activeFilterCount: Int {
        var count = 0
        if selectedGameTypeRaw != nil { count += 1 }
        if selectedStakes != nil { count += 1 }
        if selectedVenue != nil { count += 1 }
        if selectedDatePreset != .allTime { count += 1 }
        return count
    }

    // MARK: - Date Range

    private var activeDateRange: (start: Date, end: Date)? {
        if selectedDatePreset == .custom {
            return (customDateStart, Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: customDateEnd) ?? customDateEnd)
        }
        return selectedDatePreset.dateRange()
    }

    // MARK: - Computed Properties

    private var filteredTournaments: [Tournament] {
        switch selectedFilter {
        case .all, .tournaments:
            return completedTournaments.filter { matchesAdvancedFilters(gameType: $0.gameTypeRaw, venue: $0.venueName, stakes: nil, date: $0.endDate ?? $0.startDate) }
        case .cash:
            return []
        }
    }

    private var filteredCashSessions: [CashSession] {
        switch selectedFilter {
        case .all, .cash:
            return completedCashSessions.filter { matchesAdvancedFilters(gameType: $0.gameTypeRaw, venue: $0.venueName, stakes: $0.stakes, date: $0.endTime ?? $0.startTime) }
        case .tournaments:
            return []
        }
    }

    private func matchesAdvancedFilters(gameType: String, venue: String?, stakes: String?, date: Date) -> Bool {
        if let gt = selectedGameTypeRaw, gameType != gt {
            return false
        }
        if let sv = selectedVenue, venue != sv {
            return false
        }
        if let ss = selectedStakes, stakes != ss {
            return false
        }
        if let range = activeDateRange {
            if date < range.start || date > range.end {
                return false
            }
        }
        return true
    }

    private var allSessions: [SessionItem] {
        var items: [SessionItem] = []

        if selectedFilter != .cash {
            for t in filteredTournaments {
                let detail = buildTournamentDetail(t)
                items.append(SessionItem(
                    id: "t-\(t.persistentModelID)",
                    date: t.endDate ?? t.startDate,
                    name: t.name,
                    venue: t.venueName,
                    stakes: nil,
                    gameTypeRaw: t.gameTypeRaw,
                    duration: t.durationFormatted,
                    detailLine: detail,
                    profit: t.profit,
                    isTournament: true,
                    tournament: t,
                    cashSession: nil
                ))
            }
        }

        if selectedFilter != .tournaments {
            for c in filteredCashSessions {
                let detail = buildCashDetail(c)
                items.append(SessionItem(
                    id: "c-\(c.persistentModelID)",
                    date: c.endTime ?? c.startTime,
                    name: c.displayName,
                    venue: c.venueName,
                    stakes: c.stakes,
                    gameTypeRaw: c.gameTypeRaw,
                    duration: c.durationFormatted,
                    detailLine: detail,
                    profit: c.profit,
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

    private func filteredWinRate(_ sessions: [SessionItem]) -> Double {
        guard !sessions.isEmpty else { return 0 }
        let wins = sessions.filter { ($0.profit ?? 0) > 0 }.count
        return Double(wins) / Double(sessions.count) * 100
    }

    private func filteredTotalProfit(_ sessions: [SessionItem]) -> Int {
        sessions.reduce(0) { $0 + ($1.profit ?? 0) }
    }

    private func cumulativePLData(_ sessions: [SessionItem]) -> [(session: Int, date: Date, cumulative: Int)] {
        let sorted = sessions.sorted { $0.date < $1.date }
        var running = 0
        return sorted.enumerated().map { index, item in
            running += item.profit ?? 0
            return (session: index + 1, date: item.date, cumulative: running)
        }
    }

    // MARK: - Rate Stat (BB/hr for cash where stakes parse; $/hr otherwise)

    /// Parses the big blind from a stakes string like "1/2", "$2/$5", or
    /// "1/3/6" (SB/BB[/straddle] notation — the second number is the BB).
    static func bigBlind(from stakes: String) -> Double? {
        let numbers = stakes
            .components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .compactMap { Double($0) }
            .filter { $0 > 0 }
        guard numbers.count >= 2 else { return nil }
        return numbers[1]
    }

    /// Aggregate rate across the displayed sessions. When viewing cash only
    /// and every counted session has a parseable big blind, reports BB/hr;
    /// otherwise falls back to $/hr.
    private var rateStat: (value: String, isPositive: Bool) {
        let cash = filteredCashSessions.filter { $0.profit != nil && ($0.duration ?? 0) > 0 }

        if selectedFilter == .cash, !cash.isEmpty {
            let bbRates = cash.compactMap { s -> (profitBB: Double, hours: Double)? in
                guard let bb = Self.bigBlind(from: s.stakes), bb > 0,
                      let profit = s.profit, let dur = s.duration, dur > 0 else { return nil }
                return (Double(profit) / bb, dur / 3600)
            }
            if bbRates.count == cash.count {
                let totalHours = bbRates.map(\.hours).reduce(0, +)
                if totalHours > 0 {
                    let rate = bbRates.map(\.profitBB).reduce(0, +) / totalHours
                    return (String(format: "%+.1f BB/hr", rate), rate >= 0)
                }
            }
        }

        var profit = cash.compactMap(\.profit).reduce(0, +)
        var seconds = cash.compactMap(\.duration).reduce(0, +)
        if selectedFilter != .cash {
            let tourneys = filteredTournaments.filter { $0.profit != nil && ($0.duration ?? 0) > 0 }
            profit += tourneys.compactMap(\.profit).reduce(0, +)
            seconds += tourneys.compactMap(\.duration).reduce(0, +)
        }
        guard seconds > 0 else { return ("—", true) }
        let rate = Double(profit) / (seconds / 3600)
        return (formatCurrency(Int(rate.rounded())) + "/hr", rate >= 0)
    }

    // MARK: - Monthly P/L

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter
    }()

    private func monthlyPL(_ sessions: [SessionItem]) -> [(month: String, profit: Int, sessions: Int)] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: sessions) { item -> Date in
            calendar.date(from: calendar.dateComponents([.year, .month], from: item.date)) ?? item.date
        }
        // Most recent first, capped at 12 months to keep the list light
        return grouped.keys.sorted(by: >).prefix(12).map { key in
            let group = grouped[key]!
            let profit = group.reduce(0) { $0 + ($1.profit ?? 0) }
            return (month: Self.monthFormatter.string(from: key), profit: profit, sessions: group.count)
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if hasCompletedSessions {
                    filterBar
                    if hasActiveFilters {
                        activeFilterChips
                    }
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
                        // Compute the merged list once per body evaluation
                        listContent(sessions: allSessions)
                    }
                }
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Results")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("View", selection: $viewMode) {
                        ForEach(ResultsViewMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }
            }
            .sheet(isPresented: $showFilterSheet) {
                ResultsFilterSheet(
                    selectedGameTypeRaw: $selectedGameTypeRaw,
                    selectedStakes: $selectedStakes,
                    selectedVenue: $selectedVenue,
                    selectedDatePreset: $selectedDatePreset,
                    customDateStart: $customDateStart,
                    customDateEnd: $customDateEnd,
                    availableGameTypes: availableGameTypes,
                    availableStakes: availableStakes,
                    availableVenues: availableVenues
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(ResultsFilter.allCases, id: \.self) { filter in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedFilter = filter
                        // Clear stakes filter when switching to tournaments-only
                        if filter == .tournaments {
                            selectedStakes = nil
                        }
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

            // Filter button
            Button {
                showFilterSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 14, weight: .medium))
                    if activeFilterCount > 0 {
                        Text("\(activeFilterCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.backgroundPrimary)
                            .frame(width: 18, height: 18)
                            .background(Color.goldAccent)
                            .clipShape(Circle())
                    }
                }
                .foregroundColor(hasActiveFilters ? .goldAccent : .textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(hasActiveFilters ? Color.goldAccent.opacity(0.15) : Color.clear)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(hasActiveFilters ? Color.goldAccent.opacity(0.3) : Color.borderSubtle, lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Active Filter Chips

    private var activeFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let gt = selectedGameTypeRaw {
                    dismissibleChip(GameType.label(for: gt)) {
                        withAnimation { selectedGameTypeRaw = nil }
                    }
                }
                if let stakes = selectedStakes {
                    dismissibleChip(stakes) {
                        withAnimation { selectedStakes = nil }
                    }
                }
                if let venue = selectedVenue {
                    dismissibleChip(venue) {
                        withAnimation { selectedVenue = nil }
                    }
                }
                if selectedDatePreset != .allTime {
                    let label = selectedDatePreset == .custom
                        ? "\(customDateStart.formatted(date: .abbreviated, time: .omitted)) – \(customDateEnd.formatted(date: .abbreviated, time: .omitted))"
                        : selectedDatePreset.rawValue
                    dismissibleChip(label) {
                        withAnimation { selectedDatePreset = .allTime }
                    }
                }

                Button {
                    withAnimation {
                        clearAllFilters()
                    }
                } label: {
                    Text("Clear All")
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.chipRed)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 4)
    }

    private func dismissibleChip(_ label: String, onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(PokerTypography.chatCaption)
                .foregroundColor(.textPrimary)
                .lineLimit(1)
            Button {
                onDismiss()
            } label: {
                // Visual size stays small; frame + contentShape expand the
                // tap target to ~44pt, negative padding preserves layout.
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .padding(-17)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.cardSurface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.borderSubtle, lineWidth: 0.5))
    }

    private func clearAllFilters() {
        selectedGameTypeRaw = nil
        selectedStakes = nil
        selectedVenue = nil
        selectedDatePreset = .allTime
    }

    // MARK: - List Content

    private func listContent(sessions: [SessionItem]) -> some View {
        let plData = cumulativePLData(sessions)
        let monthly = monthlyPL(sessions)

        return List {
            Section {
                aggregateStatsHeader(sessions: sessions)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
            }

            if plData.count >= 2 {
                Section {
                    cumulativePLChart(data: plData)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                }
            }

            if monthly.count >= 2 {
                Section {
                    monthlyPLSection(monthly)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                }
            }

            Section {
                if sessions.isEmpty && hasActiveFilters {
                    noFilterResults
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(sessions) { session in
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
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
    }

    // MARK: - No Filter Results

    private var noFilterResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 40))
                .foregroundColor(.textSecondary.opacity(0.5))

            Text("No matching sessions")
                .font(.headline)
                .foregroundColor(.textPrimary)

            Text("Try adjusting your filters")
                .font(PokerTypography.chatBody)
                .foregroundColor(.textSecondary)

            Button {
                withAnimation { clearAllFilters() }
            } label: {
                Text("Clear Filters")
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(.goldAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.goldAccent.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
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

    private func aggregateStatsHeader(sessions: [SessionItem]) -> some View {
        let totalProfit = filteredTotalProfit(sessions)
        let rate = rateStat

        return HStack(spacing: 0) {
            statColumn(value: "\(sessions.count)", label: "Sessions")
            Divider().frame(height: 32).overlay(Color.borderSubtle)
            statColumn(
                value: String(format: "%.0f%%", filteredWinRate(sessions)),
                label: "Win Rate"
            )
            Divider().frame(height: 32).overlay(Color.borderSubtle)
            statColumn(
                value: formatCurrency(totalProfit),
                label: "Profit",
                color: totalProfit >= 0 ? .mZoneGreen : .chipRed
            )
            Divider().frame(height: 32).overlay(Color.borderSubtle)
            statColumn(
                value: rate.value,
                label: "Rate",
                color: rate.isPositive ? .mZoneGreen : .chipRed
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

    private func cumulativePLChart(data: [(session: Int, date: Date, cumulative: Int)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CUMULATIVE P/L")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.textSecondary)

            Chart {
                ForEach(data, id: \.session) { point in
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

                if let last = data.last {
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

                if let scrub = plScrubSession,
                   let point = data.first(where: { $0.session == scrub }) {
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
                                        plScrubSession = data.min {
                                            abs($0.session - session) < abs($1.session - session)
                                        }?.session
                                    }
                                }
                                .onEnded { _ in plScrubSession = nil }
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
        }
        .pokerCard()
    }

    // MARK: - Monthly P/L Section

    private func monthlyPLSection(_ monthly: [(month: String, profit: Int, sessions: Int)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MONTHLY P/L")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.textSecondary)

            ForEach(monthly, id: \.month) { stat in
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

    private func profitBadge(_ profit: Int?) -> some View {
        let color: Color
        let text: String
        if let profit {
            let isPositive = profit >= 0
            color = isPositive ? .mZoneGreen : .chipRed
            text = isPositive ? "+\(formatCurrency(profit))" : formatCurrency(profit)
        } else {
            // No result recorded (e.g. payout never entered)
            color = .textSecondary
            text = "—"
        }

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

// MARK: - Chart Scrub Callout

/// Small callout card shown while scrubbing a chart with a finger.
/// Shared by the Results, Analytics, and Stack charts.
struct ChartScrubCallout: View {
    let title: String
    let value: String
    var valueColor: Color = .goldAccent

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(PokerTypography.chatCaption)
                .foregroundColor(.textSecondary)
            Text(value)
                .font(PokerTypography.statValue)
                .foregroundColor(valueColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.goldAccent.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Results Filter Sheet

struct ResultsFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var selectedGameTypeRaw: String?
    @Binding var selectedStakes: String?
    @Binding var selectedVenue: String?
    @Binding var selectedDatePreset: DateRangePreset
    @Binding var customDateStart: Date
    @Binding var customDateEnd: Date

    let availableGameTypes: [(rawValue: String, label: String)]
    let availableStakes: [String]
    let availableVenues: [String]

    var body: some View {
        NavigationStack {
            List {
                // Game Type
                Section {
                    filterRow("All Game Types", isSelected: selectedGameTypeRaw == nil) {
                        selectedGameTypeRaw = nil
                    }
                    ForEach(availableGameTypes, id: \.rawValue) { gt in
                        filterRow(gt.label, isSelected: selectedGameTypeRaw == gt.rawValue) {
                            selectedGameTypeRaw = gt.rawValue
                        }
                    }
                } header: {
                    Text("GAME TYPE")
                        .font(PokerTypography.sectionHeader)
                        .foregroundColor(.textSecondary)
                }
                .listRowBackground(Color.cardSurface)

                // Stakes (only if cash sessions exist)
                if !availableStakes.isEmpty {
                    Section {
                        filterRow("All Stakes", isSelected: selectedStakes == nil) {
                            selectedStakes = nil
                        }
                        ForEach(availableStakes, id: \.self) { stakes in
                            filterRow(stakes, isSelected: selectedStakes == stakes) {
                                selectedStakes = stakes
                            }
                        }
                    } header: {
                        Text("STAKES")
                            .font(PokerTypography.sectionHeader)
                            .foregroundColor(.textSecondary)
                    }
                    .listRowBackground(Color.cardSurface)
                }

                // Location
                if !availableVenues.isEmpty {
                    Section {
                        filterRow("All Locations", isSelected: selectedVenue == nil) {
                            selectedVenue = nil
                        }
                        ForEach(availableVenues, id: \.self) { venue in
                            filterRow(venue, isSelected: selectedVenue == venue) {
                                selectedVenue = venue
                            }
                        }
                    } header: {
                        Text("LOCATION")
                            .font(PokerTypography.sectionHeader)
                            .foregroundColor(.textSecondary)
                    }
                    .listRowBackground(Color.cardSurface)
                }

                // Date Range
                Section {
                    ForEach(DateRangePreset.allCases.filter { $0 != .custom }, id: \.self) { preset in
                        filterRow(preset.rawValue, isSelected: selectedDatePreset == preset) {
                            selectedDatePreset = preset
                        }
                    }
                    filterRow("Custom Range", isSelected: selectedDatePreset == .custom) {
                        selectedDatePreset = .custom
                    }

                    if selectedDatePreset == .custom {
                        DatePicker("From", selection: $customDateStart, in: ...customDateEnd, displayedComponents: .date)
                            .font(PokerTypography.chatBody)
                            .foregroundColor(.textPrimary)
                            .tint(.goldAccent)

                        DatePicker("To", selection: $customDateEnd, in: customDateStart..., displayedComponents: .date)
                            .font(PokerTypography.chatBody)
                            .foregroundColor(.textPrimary)
                            .tint(.goldAccent)
                    }
                } header: {
                    Text("DATE RANGE")
                        .font(PokerTypography.sectionHeader)
                        .foregroundColor(.textSecondary)
                }
                .listRowBackground(Color.cardSurface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.backgroundPrimary)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        selectedGameTypeRaw = nil
                        selectedStakes = nil
                        selectedVenue = nil
                        selectedDatePreset = .allTime
                    }
                    .foregroundColor(.chipRed)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.goldAccent)
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func filterRow(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                action()
            }
        } label: {
            HStack {
                Text(label)
                    .font(PokerTypography.chatBody)
                    .foregroundColor(.textPrimary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.goldAccent)
                }
            }
        }
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
