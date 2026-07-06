import SwiftUI
import SwiftData

@main
struct StackTrackerProApp: App {
    @State private var tournamentManager: TournamentManager
    @State private var chatManager: ChatManager
    @State private var cashSessionManager = CashSessionManager()
    @State private var showSplash = true

    init() {
        let tournamentManager = TournamentManager()
        _tournamentManager = State(initialValue: tournamentManager)
        _chatManager = State(initialValue: ChatManager(tournamentManager: tournamentManager))
    }

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
            BreakEntry.self,
            BlindStructureTemplate.self,
            TournamentEvent.self,
            Hand.self,
            HandAction.self,
        ])

        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .private("iCloud.com.gyndok.stacktrackerpro")
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // If the store is incompatible (failed schema migration), move the store
            // files aside as a backup — never delete user data — and retry with the
            // same CloudKit-backed configuration.
            let storeURL = URL.applicationSupportDirectory.appending(path: "default.store")
            let fileManager = FileManager.default
            for suffix in ["", "-wal", "-shm"] {
                let fileURL = URL(filePath: storeURL.path() + suffix)
                let backupURL = URL(filePath: storeURL.path() + ".backup" + suffix)
                try? fileManager.removeItem(at: backupURL)
                try? fileManager.moveItem(at: fileURL, to: backupURL)
            }
            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                fatalError("Could not create ModelContainer even after moving the existing store aside (backup kept at default.store.backup): \(error)")
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
                        migrateNilPayouts(context: sharedModelContainer.mainContext)
                    }
                    .environment(tournamentManager)
                    .environment(chatManager)
                    .environment(cashSessionManager)

                if showSplash {
                    SplashScreenView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
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

    /// Idempotent fix: completed tournaments with nil payout should be 0
    /// so profit calculates correctly as a loss. Runs on every launch so
    /// records that later sync down from devices on older versions are
    /// also repaired.
    private func migrateNilPayouts(context: ModelContext) {
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
        } catch {
            // Non-fatal — will retry next launch
        }
    }
}
