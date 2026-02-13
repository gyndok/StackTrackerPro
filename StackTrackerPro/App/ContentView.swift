import SwiftUI

struct ContentView: View {
    @Environment(TournamentManager.self) private var tournamentManager

    enum PlayMode: String, CaseIterable {
        case tournaments = "Tournaments"
        case cashGames = "Cash Games"
    }

    @State private var selectedPlayMode: PlayMode = .tournaments

    var body: some View {
        TabView {
            Tab("Play", systemImage: "suit.spade.fill") {
                NavigationStack {
                    VStack(spacing: 0) {
                        // Segmented picker
                        Picker("Mode", selection: $selectedPlayMode) {
                            ForEach(PlayMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                        // Content based on selection
                        switch selectedPlayMode {
                        case .tournaments:
                            TournamentListView()
                        case .cashGames:
                            CashSessionListView()
                        }
                    }
                    .background(Color.backgroundPrimary)
                    .navigationTitle("Stack Tracker Pro")
                }
            }

            Tab("Results", systemImage: "chart.line.uptrend.xyaxis") {
                TournamentHistoryView()
            }

            Tab("Settings", systemImage: "gearshape.fill") {
                SettingsView()
            }
        }
        .tint(.goldAccent)
        .preferredColorScheme(.dark)
    }

}

#Preview {
    ContentView()
        .modelContainer(for: Tournament.self, inMemory: true)
        .environment(TournamentManager())
        .environment(CashSessionManager())
        .environment(ChatManager(tournamentManager: TournamentManager()))
}
