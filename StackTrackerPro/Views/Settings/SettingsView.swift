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
    static let appTheme = "settings.display.appTheme"
    static let swingSensitivity = "settings.hands.swingSensitivity"
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(TournamentManager.self) private var tournamentManager
    @Environment(CashSessionManager.self) private var cashSessionManager

    // Session Defaults
    @AppStorage(SettingsKeys.defaultGameType) private var defaultGameType = GameType.nlh.rawValue
    @AppStorage(SettingsKeys.defaultStartingChips) private var defaultStartingChips = 20000
    @AppStorage(SettingsKeys.defaultPayoutPercent) private var defaultPayoutPercent = 15
    @AppStorage(SettingsKeys.defaultSeatsPerTable) private var defaultSeatsPerTable = 9
    @AppStorage(SettingsKeys.defaultStakes) private var defaultStakes = "1/2"
    @AppStorage(SettingsKeys.swingSensitivity) private var swingSensitivity = 20

    // Display & Appearance
    @AppStorage(SettingsKeys.keepScreenAwake) private var keepScreenAwake = true
    @AppStorage(SettingsKeys.hapticFeedback) private var hapticFeedback = true
    @AppStorage(SettingsKeys.showMRatio) private var showMRatio = false
    @AppStorage(SettingsKeys.milestoneCelebrations) private var milestoneCelebrations = true
    @AppStorage(SettingsKeys.appTheme) private var appTheme = AppTheme.midnight.rawValue

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
    @State private var exportResult: CSVExportResult?
    @State private var showExportShare = false
    @State private var exportFileURL: URL?
    @State private var showExportError = false

    private var gameTypeRawBinding: Binding<String> {
        Binding(
            get: { defaultGameType },
            set: { defaultGameType = $0 }
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.backgroundPrimary.ignoresSafeArea()

                Form {
                    themeSection
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

    // MARK: - Theme

    private var themeSection: some View {
        Section {
            ForEach(AppTheme.allCases) { theme in
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        // Writing through ThemeManager notifies all observing
                        // views; its didSet persists the choice to UserDefaults.
                        ThemeManager.shared.theme = theme
                    }
                } label: {
                    HStack(spacing: 12) {
                        // Color swatches
                        HStack(spacing: 3) {
                            Circle().fill(theme.palette.backgroundPrimary).frame(width: 18, height: 18)
                            Circle().fill(theme.palette.cardSurface).frame(width: 18, height: 18)
                            Circle().fill(theme.palette.goldAccent).frame(width: 18, height: 18)
                        }
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(theme.rawValue)
                                .font(.body.weight(.medium))
                                .foregroundColor(.textPrimary)
                            Text(theme.description)
                                .font(PokerTypography.chatCaption)
                                .foregroundColor(.textSecondary)
                        }

                        Spacer()

                        if appTheme == theme.rawValue {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.goldAccent)
                                .font(.title3)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityAddTraits(appTheme == theme.rawValue ? [.isSelected] : [])
            }
        } header: {
            Text("THEME")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
        }
        .listRowBackground(Color.cardSurface)
    }

    // MARK: - Session Defaults

    private var sessionDefaultsSection: some View {
        Section {
            GameTypePickerView(selectedRawValue: gameTypeRawBinding)

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

            Picker("Big-pot detection", selection: $swingSensitivity) {
                Text("Off").tag(0)
                Text("15% of stack").tag(15)
                Text("20% of stack").tag(20)
                Text("25% of stack").tag(25)
            }
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

            Button {
                exportCSV()
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export Session History (CSV)")
                }
                .foregroundColor(.goldAccent)
            }
        } header: {
            Text("IMPORT & EXPORT")
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
                Text("Imported \(r.cashSessionsCreated) cash session\(r.cashSessionsCreated == 1 ? "" : "s") and \(r.tournamentsCreated) tournament\(r.tournamentsCreated == 1 ? "" : "s").\(r.duplicatesSkipped > 0 ? " \(r.duplicatesSkipped) duplicate\(r.duplicatesSkipped == 1 ? "" : "s") skipped." : "")\(r.rowsSkipped > 0 ? " \(r.rowsSkipped) row\(r.rowsSkipped == 1 ? "" : "s") skipped." : "")")
            }
        }
        .sheet(isPresented: $showExportShare) {
            if let url = exportFileURL {
                ShareSheetView(items: [url])
                    .presentationDetents([.medium])
            }
        }
        .alert("Export Failed", isPresented: $showExportError) {
            Button("OK") {}
        } message: {
            Text("Your session history could not be exported. Please try again.")
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
                item: URL(string: "https://apps.apple.com/us/app/pokerstacktrackerpro/id6760260251")!
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

    private func exportCSV() {
        let result = CSVExporter.exportCSV(from: modelContext)
        exportResult = result

        if result.totalRows == 0 {
            // Surface a failure if there is data but the exporter produced nothing.
            let cashCount = (try? modelContext.fetchCount(FetchDescriptor<CashSession>())) ?? 0
            if !allTournaments.isEmpty || cashCount > 0 {
                showExportError = true
            }
            return
        }

        let fileName = "StackTrackerPro_Export_\(DateFormatter.exportDateFormatter.string(from: Date())).csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try result.csvString.write(to: tempURL, atomically: true, encoding: .utf8)
            exportFileURL = tempURL
            showExportShare = true
        } catch {
            showExportError = true
        }
    }

    private func deleteAllData() {
        // Clear active references so managers don't touch deleted objects
        tournamentManager.activeTournament = nil
        cashSessionManager.activeSession = nil

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
        UserDefaults.standard.removeObject(forKey: "MilestoneTracker.bestCashAmount")

        // Save
        try? modelContext.save()

        // Update photo stats
        photoCount = 0
        photoSizeMB = 0.0

        HapticFeedback.notification(.success)
    }
}

// MARK: - Share Sheet

struct ShareSheetView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Export Date Formatter

extension DateFormatter {
    static let exportDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

#Preview {
    SettingsView()
        .modelContainer(for: Tournament.self, inMemory: true)
        .environment(TournamentManager())
        .environment(CashSessionManager())
}
