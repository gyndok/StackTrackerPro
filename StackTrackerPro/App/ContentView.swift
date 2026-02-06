import SwiftUI

struct ContentView: View {
    @Environment(TournamentManager.self) private var tournamentManager

    var body: some View {
        TabView {
            Tab("Play", systemImage: "suit.spade.fill") {
                TournamentListView()
            }

            Tab("History", systemImage: "clock.fill") {
                historyPlaceholder
            }

            Tab("Settings", systemImage: "gearshape.fill") {
                settingsPlaceholder
            }
        }
        .tint(.goldAccent)
        .preferredColorScheme(.dark)
    }

    private var historyPlaceholder: some View {
        NavigationStack {
            ZStack {
                Color.backgroundPrimary.ignoresSafeArea()
                VStack(spacing: 12) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.textSecondary.opacity(0.5))
                    Text("Tournament History")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.textPrimary)
                    Text("Coming in Phase 2")
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)
                }
            }
            .navigationTitle("History")
        }
    }

    private var settingsPlaceholder: some View {
        NavigationStack {
            ZStack {
                Color.backgroundPrimary.ignoresSafeArea()
                VStack(spacing: 12) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.textSecondary.opacity(0.5))
                    Text("Settings")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.textPrimary)
                    Text("Coming in Phase 2")
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Tournament.self, inMemory: true)
        .environment(TournamentManager())
        .environment(ChatManager(tournamentManager: TournamentManager()))
}
