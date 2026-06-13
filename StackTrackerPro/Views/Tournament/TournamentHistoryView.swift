import SwiftUI
import SwiftData

struct TournamentHistoryView: View {
    enum ViewMode: String, CaseIterable {
        case list = "List"
        case analytics = "Analytics"
    }

    enum SortOption: String, CaseIterable {
        case dateNewest = "Newest First"
        case dateOldest = "Oldest First"
        case profitHigh = "Highest Profit"
        case profitLow = "Lowest Profit"
        case buyInHigh = "Highest Buy-in"
        case buyInLow = "Lowest Buy-in"
        case bestFinish = "Best Finish"
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(TournamentManager.self) private var tournamentManager
    @Query(filter: #Predicate<Tournament> { $0.statusRaw == "completed" },
           sort: \Tournament.endDate, order: .reverse)
    private var completedTournaments: [Tournament]

    @State private var tournamentForXShare: Tournament?
    @State private var tournamentForVideo: Tournament?
    @State private var viewMode: ViewMode = .list

    // Search / sort / filter
    @State private var searchText = ""
    @State private var sortOption: SortOption = .dateNewest
    @State private var selectedGameTypeRaw: String?
    @State private var selectedVenue: String?
    @State private var selectedDatePreset: DateRangePreset = .allTime
    @State private var customDateStart: Date = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var customDateEnd: Date = .now
    @State private var showFilterSheet = false

    // MARK: - Filter Options (derived from data)

    private var availableGameTypes: [(rawValue: String, label: String)] {
        let types = Set(completedTournaments.map(\.gameTypeRaw))
        return types.map { ($0, GameType.label(for: $0)) }.sorted { $0.label < $1.label }
    }

    private var availableVenues: [String] {
        Set(completedTournaments.compactMap(\.venueName)).sorted()
    }

    private var hasActiveFilters: Bool {
        selectedGameTypeRaw != nil || selectedVenue != nil || selectedDatePreset != .allTime
    }

    private var activeFilterCount: Int {
        var count = 0
        if selectedGameTypeRaw != nil { count += 1 }
        if selectedVenue != nil { count += 1 }
        if selectedDatePreset != .allTime { count += 1 }
        return count
    }

    private var activeDateRange: (start: Date, end: Date)? {
        if selectedDatePreset == .custom {
            return (customDateStart, Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: customDateEnd) ?? customDateEnd)
        }
        return selectedDatePreset.dateRange()
    }

    // MARK: - Filtered + Sorted Tournaments

    private var displayedTournaments: [Tournament] {
        var result = completedTournaments.filter { t in
            if let gt = selectedGameTypeRaw, t.gameTypeRaw != gt {
                return false
            }
            if let venue = selectedVenue, t.venueName != venue {
                return false
            }
            if let range = activeDateRange {
                let date = t.endDate ?? t.startDate
                if date < range.start || date > range.end {
                    return false
                }
            }
            return true
        }

        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || ($0.venueName?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }

        switch sortOption {
        case .dateNewest:
            break // @Query order is already newest-first
        case .dateOldest:
            result.reverse()
        case .profitHigh:
            // Unresolved (nil-payout) tournaments sort last
            result.sort { ($0.profit ?? Int.min) > ($1.profit ?? Int.min) }
        case .profitLow:
            result.sort { ($0.profit ?? Int.max) < ($1.profit ?? Int.max) }
        case .buyInHigh:
            result.sort { $0.totalInvestment > $1.totalInvestment }
        case .buyInLow:
            result.sort { $0.totalInvestment < $1.totalInvestment }
        case .bestFinish:
            // Tournaments with no recorded finish sort last
            result.sort { ($0.finishPosition ?? Int.max) < ($1.finishPosition ?? Int.max) }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !completedTournaments.isEmpty {
                    Picker("View", selection: $viewMode) {
                        ForEach(ViewMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    if viewMode == .list {
                        sortFilterBar
                    }
                }

                ZStack {
                    Color.backgroundPrimary.ignoresSafeArea()

                    if completedTournaments.isEmpty {
                        emptyState
                    } else if viewMode == .analytics {
                        AnalyticsDashboardView(tournaments: completedTournaments)
                    } else {
                        tournamentList
                    }
                }
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("History")
            .sheet(item: $tournamentForXShare) { tournament in
                XShareComposeView(tournament: tournament, context: .completed)
            }
            .fullScreenCover(item: $tournamentForVideo) { tournament in
                VideoExportSheet(tournament: tournament)
            }
            .sheet(isPresented: $showFilterSheet) {
                ResultsFilterSheet(
                    selectedGameTypeRaw: $selectedGameTypeRaw,
                    selectedStakes: .constant(nil),
                    selectedVenue: $selectedVenue,
                    selectedDatePreset: $selectedDatePreset,
                    customDateStart: $customDateStart,
                    customDateEnd: $customDateEnd,
                    availableGameTypes: availableGameTypes,
                    availableStakes: [],
                    availableVenues: availableVenues
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Sort / Filter Bar

    private var sortFilterBar: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Sort", selection: $sortOption) {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .medium))
                    Text(sortOption.rawValue)
                        .font(PokerTypography.chipLabel)
                        .lineLimit(1)
                }
                .foregroundColor(.goldAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.goldAccent.opacity(0.15))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.goldAccent.opacity(0.3), lineWidth: 1))
            }
            .accessibilityLabel("Sort tournaments, currently \(sortOption.rawValue)")

            Spacer()

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
            .accessibilityLabel(activeFilterCount > 0 ? "Filters, \(activeFilterCount) active" : "Filters")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.fill")
                .font(.system(size: 60))
                .foregroundColor(.goldAccent.opacity(0.5))

            Text("No Completed Tournaments")
                .font(.title2.weight(.semibold))
                .foregroundColor(.textPrimary)

            Text("Finished tournaments will appear here\nwith results and stats")
                .font(PokerTypography.chatBody)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    // MARK: - No Filter Results

    private var noFilterResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 40))
                .foregroundColor(.textSecondary.opacity(0.5))

            Text("No matching tournaments")
                .font(.headline)
                .foregroundColor(.textPrimary)

            Text("Try adjusting your search or filters")
                .font(PokerTypography.chatBody)
                .foregroundColor(.textSecondary)

            if hasActiveFilters {
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
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func clearAllFilters() {
        selectedGameTypeRaw = nil
        selectedVenue = nil
        selectedDatePreset = .allTime
    }

    // MARK: - Tournament List

    private var tournamentList: some View {
        let displayed = displayedTournaments

        return List {
            Section {
                aggregateStatsHeader(displayed)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
            }

            Section {
                if displayed.isEmpty {
                    noFilterResults
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(displayed, id: \.persistentModelID) { tournament in
                        NavigationLink {
                            ActiveSessionView(tournament: tournament)
                        } label: {
                            historyRow(tournament)
                        }
                        .contextMenu {
                            Button {
                                tournamentForXShare = tournament
                            } label: {
                                Label("Post to X", systemImage: "square.and.arrow.up.fill")
                            }

                            if !tournament.sortedStackEntries.isEmpty {
                                Button {
                                    tournamentForVideo = tournament
                                } label: {
                                    Label("Create Video", systemImage: "film")
                                }
                            }
                        }
                        .listRowBackground(Color.cardSurface)
                    }
                    .onDelete(perform: deleteTournaments)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Search name or venue")
    }

    // MARK: - Aggregate Stats Header

    private func aggregateStatsHeader(_ tournaments: [Tournament]) -> some View {
        let sessions = tournaments.count
        let wins = tournaments.filter { ($0.profit ?? 0) > 0 }.count
        let winRate = sessions > 0 ? Double(wins) / Double(sessions) * 100 : 0
        let totalProfit = tournaments.compactMap(\.profit).reduce(0, +)
        let avgHourly: Double = {
            let rates = tournaments.compactMap(\.hourlyRate)
            guard !rates.isEmpty else { return 0 }
            return rates.reduce(0, +) / Double(rates.count)
        }()

        return HStack(spacing: 0) {
            statColumn(value: "\(sessions)", label: "Sessions")
            Divider().frame(height: 32).overlay(Color.borderSubtle)
            statColumn(value: String(format: "%.0f%%", winRate), label: "Win Rate")
            Divider().frame(height: 32).overlay(Color.borderSubtle)
            statColumn(
                value: formatCurrency(totalProfit),
                label: "Profit",
                color: totalProfit >= 0 ? .mZoneGreen : .chipRed
            )
            Divider().frame(height: 32).overlay(Color.borderSubtle)
            statColumn(
                value: formatCurrency(Int(avgHourly.rounded())) + "/hr",
                label: "Avg Rate",
                color: avgHourly >= 0 ? .mZoneGreen : .chipRed
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

    // MARK: - History Row

    private func historyRow(_ tournament: Tournament) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tournament.name)
                    .font(.headline)
                    .foregroundColor(.textPrimary)

                HStack(spacing: 8) {
                    Text(tournament.gameTypeLabel)
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)

                    if let venue = tournament.venueName {
                        Text(venue)
                            .font(PokerTypography.chipLabel)
                            .foregroundColor(.textSecondary)
                    }
                }

                if let endDate = tournament.endDate {
                    Text(endDate.formatted(date: .abbreviated, time: .omitted))
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)
                }

                detailLine(tournament)
            }

            Spacer()

            profitBadge(tournament)
        }
        .padding(.vertical, 4)
    }

    private func detailLine(_ tournament: Tournament) -> some View {
        HStack(spacing: 4) {
            Text(tournament.durationFormatted)
                .font(PokerTypography.chatCaption)
                .foregroundColor(.textSecondary)

            if let finish = tournament.finishPosition {
                Text("·")
                    .foregroundColor(.textSecondary)
                Text(ordinal(finish) + (tournament.fieldSize > 0 ? " of \(tournament.fieldSize)" : ""))
                    .font(PokerTypography.chatCaption)
                    .foregroundColor(.textSecondary)
            }

            Text("·")
                .foregroundColor(.textSecondary)
            Text("$\(tournament.totalInvestment) buy-in")
                .font(PokerTypography.chatCaption)
                .foregroundColor(.textSecondary)
        }
    }

    private func profitBadge(_ tournament: Tournament) -> some View {
        let profit = tournament.profit ?? 0
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

    // MARK: - Helpers

    private func deleteTournaments(at offsets: IndexSet) {
        let displayed = displayedTournaments
        for index in offsets {
            let tournament = displayed[index]
            if tournamentManager.activeTournament?.persistentModelID == tournament.persistentModelID {
                tournamentManager.activeTournament = nil
            }
            modelContext.delete(tournament)
        }
    }

    private func formatCurrency(_ amount: Int) -> String {
        if amount < 0 {
            return "-$\(abs(amount))"
        }
        return "$\(amount)"
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

#Preview {
    TournamentHistoryView()
        .modelContainer(for: Tournament.self, inMemory: true)
        .environment(TournamentManager())
}
