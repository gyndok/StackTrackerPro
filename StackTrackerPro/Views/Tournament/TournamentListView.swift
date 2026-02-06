import SwiftUI
import SwiftData

struct TournamentListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(TournamentManager.self) private var tournamentManager
    @Query(sort: \Tournament.startDate, order: .reverse) private var tournaments: [Tournament]

    @State private var showingSetup = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.backgroundPrimary.ignoresSafeArea()

                if tournaments.isEmpty {
                    emptyState
                } else {
                    tournamentList
                }
            }
            .navigationTitle("Stack Tracker Pro")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSetup = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.goldAccent)
                    }
                }
            }
            .sheet(isPresented: $showingSetup) {
                TournamentSetupView()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "suit.spade.fill")
                .font(.system(size: 60))
                .foregroundColor(.goldAccent.opacity(0.5))

            Text("No Tournaments")
                .font(.title2.weight(.semibold))
                .foregroundColor(.textPrimary)

            Text("Tap + to start tracking your first tournament")
                .font(PokerTypography.chatBody)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                showingSetup = true
            } label: {
                Text("New Tournament")
            }
            .buttonStyle(PokerButtonStyle(isEnabled: true))
            .padding(.horizontal, 40)
            .padding(.top, 8)
        }
        .padding()
    }

    private var tournamentList: some View {
        List {
            ForEach(tournaments, id: \.persistentModelID) { tournament in
                NavigationLink {
                    destinationView(for: tournament)
                } label: {
                    tournamentRow(tournament)
                }
                .listRowBackground(Color.cardSurface)
            }
            .onDelete(perform: deleteTournaments)
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
    }

    @ViewBuilder
    private func destinationView(for tournament: Tournament) -> some View {
        if tournament.status == .active || tournament.status == .paused {
            ActiveSessionView(tournament: tournament)
        } else if tournament.status == .setup {
            TournamentSetupView(tournament: tournament)
        } else {
            ActiveSessionView(tournament: tournament)
        }
    }

    private func tournamentRow(_ tournament: Tournament) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tournament.name)
                    .font(.headline)
                    .foregroundColor(.textPrimary)

                HStack(spacing: 8) {
                    Text(tournament.gameType.label)
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)

                    if let venue = tournament.venueName {
                        Text(venue)
                            .font(PokerTypography.chipLabel)
                            .foregroundColor(.textSecondary)
                    }
                }

                Text(tournament.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(PokerTypography.chatCaption)
                    .foregroundColor(.textSecondary)
            }

            Spacer()

            statusBadge(tournament.status)
        }
        .padding(.vertical, 4)
    }

    private func statusBadge(_ status: TournamentStatus) -> some View {
        HStack(spacing: 4) {
            Image(systemName: status.icon)
                .font(.caption2)
            Text(status.label)
                .font(PokerTypography.chipLabel)
        }
        .foregroundColor(status.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(status.color.opacity(0.15))
        .clipShape(Capsule())
    }

    private func deleteTournaments(at offsets: IndexSet) {
        for index in offsets {
            let tournament = tournaments[index]
            if tournamentManager.activeTournament?.persistentModelID == tournament.persistentModelID {
                tournamentManager.activeTournament = nil
            }
            modelContext.delete(tournament)
        }
    }
}

#Preview {
    TournamentListView()
        .modelContainer(for: Tournament.self, inMemory: true)
        .environment(TournamentManager())
}
