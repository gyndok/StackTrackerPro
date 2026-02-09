import SwiftUI
import SwiftData

@main
struct StackTrackerProApp: App {
    @State private var tournamentManager = TournamentManager()
    @State private var chatManager: ChatManager?
    @State private var showSplash = true

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Tournament.self,
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
                cloudKitDatabase: .none
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
                        if chatManager == nil {
                            chatManager = ChatManager(tournamentManager: tournamentManager)
                        }
                    }
                    .environment(tournamentManager)
                    .environment(chatManager ?? ChatManager(tournamentManager: tournamentManager))

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
}
