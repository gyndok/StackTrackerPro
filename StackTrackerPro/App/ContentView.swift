import SwiftUI

/// Spec 2026-07-21: after a real backgrounding of ≥ threshold during an
/// active tournament, the app returns to the Play tab — brief app-switches
/// and out-of-session browsing keep the user's place.
enum ForegroundSnap {
    static func shouldSnapToPlay(backgroundedAt: Date?, now: Date,
                                 hasActiveTournament: Bool,
                                 threshold: TimeInterval = 300) -> Bool {
        guard let backgroundedAt, hasActiveTournament else { return false }
        return now.timeIntervalSince(backgroundedAt) >= threshold
    }
}

struct ContentView: View {
    @Environment(TournamentManager.self) private var tournamentManager
    @Environment(\.scenePhase) private var scenePhase

    enum PlayMode: String, CaseIterable {
        case tournaments = "Tournaments"
        case cashGames = "Cash Games"
    }

    @State private var selectedPlayMode: PlayMode = .tournaments
    @State private var selectedTab = 0
    @State private var backgroundedAt: Date?

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
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                backgroundedAt = .now
            case .active:
                if ForegroundSnap.shouldSnapToPlay(backgroundedAt: backgroundedAt, now: .now,
                                                   hasActiveTournament: tournamentManager.activeTournament != nil) {
                    selectedTab = 0
                }
                backgroundedAt = nil
            default:
                break   // .inactive must not arm or clear the stamp
            }
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
