import SwiftUI
import SwiftData

struct TournamentHistoryView: View {
    enum ViewMode: String, CaseIterable {
        case list = "List"
        case analytics = "Analytics"
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(TournamentManager.self) private var tournamentManager
    @Query(filter: #Predicate<Tournament> { $0.statusRaw == "completed" },
           sort: \Tournament.endDate, order: .reverse)
    private var completedTournaments: [Tournament]

    @State private var tournamentForXShare: Tournament?
    @State private var viewMode: ViewMode = .list

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
        }
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

    // MARK: - Tournament List

    private var tournamentList: some View {
        List {
            Section {
                aggregateStatsHeader
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
            }

            Section {
                ForEach(completedTournaments, id: \.persistentModelID) { tournament in
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
                    }
                    .listRowBackground(Color.cardSurface)
                }
                .onDelete(perform: deleteTournaments)
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
    }

    // MARK: - Aggregate Stats Header

    private var aggregateStatsHeader: some View {
        let sessions = completedTournaments.count
        let wins = completedTournaments.filter { ($0.profit ?? 0) > 0 }.count
        let winRate = sessions > 0 ? Double(wins) / Double(sessions) * 100 : 0
        let totalProfit = completedTournaments.compactMap(\.profit).reduce(0, +)
        let avgHourly: Double = {
            let rates = completedTournaments.compactMap(\.hourlyRate)
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
                value: formatCurrency(Int(avgHourly)) + "/hr",
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
        for index in offsets {
            let tournament = completedTournaments[index]
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
