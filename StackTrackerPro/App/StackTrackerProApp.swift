import SwiftUI
import SwiftData

@main
struct StackTrackerProApp: App {
    @State private var tournamentManager = TournamentManager()
    @State private var chatManager: ChatManager?
    @State private var cashSessionManager = CashSessionManager()
    @AppStorage(SettingsKeys.appTheme) private var appTheme = AppTheme.midnight.rawValue
    @State private var showSplash = true

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Tournament.self,
            CashSession.self,
            BlindLevel.self,
            StackEntry.self,
            ChatMessage.self,
            HandNote.self,
            BountyEvent.self,
            FieldSnapshot.self,
            Venue.self,
            ChipStackPhoto.self,
        ])

        do {
            let modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .private("iCloud.com.gyndok.stacktrackerpro")
            )
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // If store is incompatible (schema migration), delete all DB files and retry
            let storeURL = URL.applicationSupportDirectory.appending(path: "default.store")
            for suffix in ["", "-wal", "-shm"] {
                let fileURL = URL(filePath: storeURL.path() + suffix)
                try? FileManager.default.removeItem(at: fileURL)
            }
            do {
                let modelConfiguration = ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: false
                )
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .onAppear {
                        tournamentManager.setContext(sharedModelContainer.mainContext)
                        cashSessionManager.setContext(sharedModelContainer.mainContext)
                        if chatManager == nil {
                            chatManager = ChatManager(tournamentManager: tournamentManager)
                        }
                        migrateNilPayouts(context: sharedModelContainer.mainContext)
                    }
                    .environment(tournamentManager)
                    .environment(chatManager ?? ChatManager(tournamentManager: tournamentManager))
                    .environment(cashSessionManager)

                if showSplash {
                    SplashScreenView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .id(appTheme)
            .preferredColorScheme(.dark)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.easeOut(duration: 0.5)) {
                        showSplash = false
                    }
                }
            }
        }
        .modelContainer(sharedModelContainer)
    }

    /// One-time fix: completed tournaments with nil payout should be 0
    /// so profit calculates correctly as a loss.
    private func migrateNilPayouts(context: ModelContext) {
        let migrationKey = "didMigrateNilPayouts"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        do {
            let descriptor = FetchDescriptor<Tournament>()
            let all = try context.fetch(descriptor)
            var changed = false
            for tournament in all where tournament.statusRaw == "completed" && tournament.payout == nil {
                tournament.payout = 0
                changed = true
            }
            if changed {
                try context.save()
            }
            UserDefaults.standard.set(true, forKey: migrationKey)
        } catch {
            // Non-fatal — will retry next launch
        }
    }
}
