import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Settings Keys

enum SettingsKeys {
    static let defaultGameType = "settings.defaults.gameType"
    static let defaultStartingChips = "settings.defaults.startingChips"
    static let defaultPayoutPercent = "settings.defaults.payoutPercent"
    static let defaultSeatsPerTable = "settings.defaults.seatsPerTable"
    static let keepScreenAwake = "settings.display.keepScreenAwake"
    static let hapticFeedback = "settings.display.hapticFeedback"
    static let showMRatio = "settings.display.showMRatio"
    static let milestoneCelebrations = "settings.display.milestoneCelebrations"
    static let defaultStakes = "settings.defaults.stakes"
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(TournamentManager.self) private var tournamentManager

    // Session Defaults
    @AppStorage(SettingsKeys.defaultGameType) private var defaultGameType = GameType.nlh.rawValue
    @AppStorage(SettingsKeys.defaultStartingChips) private var defaultStartingChips = 20000
    @AppStorage(SettingsKeys.defaultPayoutPercent) private var defaultPayoutPercent = 15
    @AppStorage(SettingsKeys.defaultSeatsPerTable) private var defaultSeatsPerTable = 9
    @AppStorage(SettingsKeys.defaultStakes) private var defaultStakes = "1/2"

    // Display & Appearance
    @AppStorage(SettingsKeys.keepScreenAwake) private var keepScreenAwake = true
    @AppStorage(SettingsKeys.hapticFeedback) private var hapticFeedback = true
    @AppStorage(SettingsKeys.showMRatio) private var showMRatio = false
    @AppStorage(SettingsKeys.milestoneCelebrations) private var milestoneCelebrations = true

    // Data queries
    @Query private var allPhotos: [ChipStackPhoto]
    @Query private var allTournaments: [Tournament]

    // State
    @State private var showDeleteConfirmation = false
    @State private var showDeleteFinalAlert = false
    @State private var photoCount = 0
    @State private var photoSizeMB = 0.0
    @State private var showFileImporter = false
    @State private var importResult: CSVImportResult?
    @State private var showImportResult = false

    private var gameTypeBinding: Binding<GameType> {
        Binding(
            get: { GameType(rawValue: defaultGameType) ?? .nlh },
            set: { defaultGameType = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.backgroundPrimary.ignoresSafeArea()

                Form {
                    sessionDefaultsSection
                    displaySection
                    importSection
                    dataSection
                    aboutSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            calculatePhotoStats()
        }
    }

    // MARK: - Session Defaults

    private var sessionDefaultsSection: some View {
        Section {
            Picker("Game Type", selection: gameTypeBinding) {
                ForEach(GameType.allCases, id: \.self) { type in
                    Text(type.label).tag(type)
                }
            }
            .tint(.goldAccent)

            HStack {
                Text("Default Stakes")
                    .foregroundColor(.textSecondary)
                Spacer()
                TextField("1/2", text: $defaultStakes)
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                Text("Starting Chips")
                    .foregroundColor(.textSecondary)
                Spacer()
                TextField("20000", value: $defaultStartingChips, format: .number)
                    .keyboardType(.numberPad)
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.trailing)
            }

            Stepper("Payout %: \(defaultPayoutPercent)", value: $defaultPayoutPercent, in: 1...100, step: 1)

            Stepper("Seats Per Table: \(defaultSeatsPerTable)", value: $defaultSeatsPerTable, in: 2...10, step: 1)
        } header: {
            Text("SESSION DEFAULTS")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
        }
        .listRowBackground(Color.cardSurface)
    }

    // MARK: - Display & Appearance

    private var displaySection: some View {
        Section {
            Toggle("Keep Screen Awake", isOn: $keepScreenAwake)
                .tint(.goldAccent)

            Toggle("Haptic Feedback", isOn: $hapticFeedback)
                .tint(.goldAccent)

            Toggle("Show M-Ratio in Status Bar", isOn: $showMRatio)
                .tint(.goldAccent)

            Toggle("Milestone Celebrations", isOn: $milestoneCelebrations)
                .tint(.goldAccent)
        } header: {
            Text("DISPLAY & APPEARANCE")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
        }
        .listRowBackground(Color.cardSurface)
    }

    // MARK: - Import

    private var importSection: some View {
        Section {
            Button {
                showFileImporter = true
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import Session History (CSV)")
                }
                .foregroundColor(.goldAccent)
            }
        } header: {
            Text("IMPORT")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
        }
        .listRowBackground(Color.cardSurface)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                importResult = CSVImporter.importCSV(from: url, into: modelContext)
                showImportResult = true
            case .failure:
                break
            }
        }
        .alert("Import Complete", isPresented: $showImportResult) {
            Button("OK") {}
        } message: {
            if let r = importResult {
                Text("Imported \(r.cashSessionsCreated) cash session\(r.cashSessionsCreated == 1 ? "" : "s") and \(r.tournamentsCreated) tournament\(r.tournamentsCreated == 1 ? "" : "s").\(r.rowsSkipped > 0 ? " \(r.rowsSkipped) row\(r.rowsSkipped == 1 ? "" : "s") skipped." : "")")
            }
        }
    }

    // MARK: - Data & Privacy

    private var dataSection: some View {
        Section {
            HStack {
                Text("Photo Storage")
                    .foregroundColor(.textPrimary)
                Spacer()
                Text("\(photoCount) photos, \(String(format: "%.1f", photoSizeMB)) MB")
                    .foregroundColor(.textSecondary)
            }

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("Delete All Data")
                }
                .foregroundColor(.chipRed)
            }
            .confirmationDialog(
                "Delete All Data?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Everything", role: .destructive) {
                    showDeleteFinalAlert = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all tournaments, venues, photos, and session history. This cannot be undone.")
            }
            .alert("Are you absolutely sure?", isPresented: $showDeleteFinalAlert) {
                Button("Delete All Data", role: .destructive) {
                    deleteAllData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All data will be permanently erased.")
            }
        } header: {
            Text("DATA & PRIVACY")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
        }
        .listRowBackground(Color.cardSurface)
    }

    // MARK: - Support & About

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                    .foregroundColor(.textPrimary)
                Spacer()
                Text(appVersion)
                    .foregroundColor(.textSecondary)
            }

            ShareLink(
                item: URL(string: "https://apps.apple.com/app/stacktrackerpro/id0000000000")!
            ) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("Share App")
                }
                .foregroundColor(.goldAccent)
            }
        } header: {
            Text("SUPPORT & ABOUT")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
        }
        .listRowBackground(Color.cardSurface)
    }

    // MARK: - Helpers

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func calculatePhotoStats() {
        photoCount = allPhotos.count
        let totalBytes = allPhotos.reduce(0) { $0 + $1.imageData.count }
        photoSizeMB = Double(totalBytes) / (1024 * 1024)
    }

    private func deleteAllData() {
        // Clear active tournament reference
        tournamentManager.activeTournament = nil

        // Delete all tournaments (cascades to BlindLevel, StackEntry, ChatMessage, HandNote, BountyEvent, FieldSnapshot, ChipStackPhoto)
        for tournament in allTournaments {
            modelContext.delete(tournament)
        }

        // Delete all cash sessions
        do {
            let cashSessions = try modelContext.fetch(FetchDescriptor<CashSession>())
            for session in cashSessions {
                modelContext.delete(session)
            }
        } catch {}

        // Delete all venues
        do {
            let venues = try modelContext.fetch(FetchDescriptor<Venue>())
            for venue in venues {
                modelContext.delete(venue)
            }
        } catch {}

        // Reset milestone tracker
        UserDefaults.standard.removeObject(forKey: "MilestoneTracker.shownMilestones")

        // Save
        try? modelContext.save()

        // Update photo stats
        photoCount = 0
        photoSizeMB = 0.0

        HapticFeedback.notification(.success)
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: Tournament.self, inMemory: true)
        .environment(TournamentManager())
}
