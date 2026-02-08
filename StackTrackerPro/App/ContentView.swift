import SwiftUI

struct ContentView: View {
    @Environment(TournamentManager.self) private var tournamentManager

    var body: some View {
        TabView {
            Tab("Play", systemImage: "suit.spade.fill") {
                TournamentListView()
            }

            Tab("History", systemImage: "clock.fill") {
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
        .environment(ChatManager(tournamentManager: TournamentManager()))
}
