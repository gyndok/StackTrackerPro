import SwiftUI

struct ContentView: View {
    @Environment(TournamentManager.self) private var tournamentManager

    enum PlayMode: String, CaseIterable {
        case tournaments = "Tournaments"
        case cashGames = "Cash Games"
    }

    @State private var selectedPlayMode: PlayMode = .tournaments
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Play", systemImage: "suit.spade.fill", value: 0) {
                NavigationStack {
                    #if DEBUG
                    if DemoData.isActive, DemoData.route != "results", let demo = DemoData.activeTournament {
                        ActiveSessionView(tournament: demo)
                    } else {
                        playRoot
                    }
                    #else
                    playRoot
                    #endif
                }
            }

            Tab("Results", systemImage: "chart.line.uptrend.xyaxis", value: 1) {
                ResultsView()
            }

            Tab("Settings", systemImage: "gearshape.fill", value: 2) {
                SettingsView()
            }
        }
        .tint(.goldAccent)
        .preferredColorScheme(.dark)
        .onAppear {
            #if DEBUG
            if DemoData.isActive && DemoData.route == "results" {
                selectedTab = 1
            }
            #endif
        }
    }

    private var playRoot: some View {
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

#Preview {
    ContentView()
        .modelContainer(for: Tournament.self, inMemory: true)
        .environment(TournamentManager())
        .environment(CashSessionManager())
        .environment(ChatManager(tournamentManager: TournamentManager()))
}
