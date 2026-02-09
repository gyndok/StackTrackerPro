import SwiftUI
import SwiftData
import PhotosUI
import CoreLocation

struct TournamentSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(TournamentManager.self) private var tournamentManager

    // Settings defaults
    @AppStorage(SettingsKeys.defaultGameType) private var savedGameType = GameType.nlh.rawValue
    @AppStorage(SettingsKeys.defaultStartingChips) private var savedStartingChips = 20000
    @AppStorage(SettingsKeys.defaultPayoutPercent) private var savedPayoutPercent = 15

    // Editing existing or creating new
    var tournament: Tournament?

    @State private var name = ""
    @State private var gameType: GameType = .nlh
    @State private var venueName = ""
    @State private var buyIn = ""
    @State private var entryFee = ""
    @State private var bountyAmount = ""
    @State private var guarantee = ""
    @State private var startingChips = "20000"
    @State private var startingSB = "100"
    @State private var startingBB = "200"
    @State private var reentryPolicy = "None"
    @State private var payoutPercent = "15"
    @State private var showBlindEditor = false
    @State private var createdTournament: Tournament?

    // Scanner state
    @State private var showingPhotoSource = false
    @State private var showingPhotoPicker = false
    @State private var showingCamera = false
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var showingScanError = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var scannedBlindLevels: [ScannedBlindLevel] = []
    @State private var showScoutingReport = false

    // CloudKit sharing
    @State private var showingBrowser = false
    @State private var shareToCloudKit = false

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        Int(startingChips) ?? 0 > 0
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.backgroundPrimary.ignoresSafeArea()

                Form {
                    scanSection
                    tournamentInfoSection
                    venueSection
                    financialsSection
                    structureSection
                    blindsSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(tournament == nil ? "New Tournament" : "Edit Tournament")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { startTournament() }
                        .foregroundColor(.goldAccent)
                        .fontWeight(.semibold)
                        .disabled(!isValid)
                }
            }
            .navigationDestination(isPresented: $showBlindEditor) {
                if let t = createdTournament ?? tournament {
                    BlindStructureEditorView(tournament: t, scannedLevels: scannedBlindLevels)
                }
            }
            .navigationDestination(isPresented: $showScoutingReport) {
                if let t = createdTournament ?? tournament {
                    ScoutingReportView(tournament: t)
                }
            }
            .sheet(isPresented: $showingCamera) {
                CameraView { image in
                    scanImages([image])
                }
            }
            .sheet(isPresented: $showingBrowser) {
                TournamentBrowserView { scanResult in
                    applyScannedResult(scanResult)
                }
            }
            .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedPhotoItems, maxSelectionCount: 10, matching: .images)
            .onChange(of: selectedPhotoItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                let items = newItems
                selectedPhotoItems = []
                Task {
                    var images: [UIImage] = []
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let uiImage = UIImage(data: data) {
                            images.append(uiImage)
                        }
                    }
                    if !images.isEmpty {
                        scanImages(images)
                    }
                }
            }
            .confirmationDialog("Scan Source", isPresented: $showingPhotoSource) {
                Button("Photo Library") { showingPhotoPicker = true }
                Button("Camera") { showingCamera = true }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Scan Error", isPresented: $showingScanError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(scanError ?? "Unknown error")
            }
            .onAppear {
                if tournament != nil {
                    loadExisting()
                } else {
                    gameType = GameType(rawValue: savedGameType) ?? .nlh
                    startingChips = "\(savedStartingChips)"
                    payoutPercent = "\(savedPayoutPercent)"
                }
            }
        }
    }

    private func buildCurrentScanResult() -> PokerAtlasScanResult {
        var result = PokerAtlasScanResult()
        result.tournamentName = name.trimmingCharacters(in: .whitespaces)
        result.venueName = venueName.trimmingCharacters(in: .whitespaces)
        result.gameType = gameType
        result.buyIn = Int(buyIn)
        result.entryFee = Int(entryFee)
        result.bountyAmount = Int(bountyAmount)
        result.guarantee = Int(guarantee)
        result.startingChips = Int(startingChips)
        result.reentryPolicy = reentryPolicy
        result.startingSB = Int(startingSB)
        result.startingBB = Int(startingBB)
        result.blindLevels = scannedBlindLevels
        return result
    }

    // MARK: - Sections

    private var scanSection: some View {
        Section {
            Button {
                showingPhotoSource = true
            } label: {
                HStack {
                    Image(systemName: "camera.viewfinder")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scan Poker Atlas Screenshot")
                            .fontWeight(.semibold)
                        Text("Auto-fill from one or more photos")
                            .font(.caption)
                            .foregroundColor(.textSecondary)
                    }
                    Spacer()
                    if isScanning {
                        ProgressView()
                            .tint(.goldAccent)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.textSecondary)
                    }
                }
                .foregroundColor(.goldAccent)
            }
            .disabled(isScanning)

            Button {
                showingBrowser = true
            } label: {
                HStack {
                    Image(systemName: "map")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Browse Nearby Events")
                            .fontWeight(.semibold)
                        Text("Find tournaments shared by other players")
                            .font(.caption)
                            .foregroundColor(.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                }
                .foregroundColor(.goldAccent)
            }

            if !name.trimmingCharacters(in: .whitespaces).isEmpty && !venueName.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack {
                    Image(systemName: "icloud.and.arrow.up")
                        .foregroundColor(.goldAccent)
                    Toggle("Share This Event", isOn: $shareToCloudKit)
                        .tint(.goldAccent)
                }
            }
        } header: {
            Text("QUICK SETUP")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
        }
        .listRowBackground(Color.cardSurface)
    }

    private var tournamentInfoSection: some View {
        Section {
            TextField("Tournament Name", text: $name)
                .foregroundColor(.textPrimary)

            Picker("Game Type", selection: $gameType) {
                ForEach(GameType.allCases, id: \.self) { type in
                    Text(type.label).tag(type)
                }
            }
            .tint(.goldAccent)
        } header: {
            Text("TOURNAMENT INFO")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
        }
        .listRowBackground(Color.cardSurface)
    }

    private var venueSection: some View {
        Section {
            TextField("Venue Name", text: $venueName)
                .foregroundColor(.textPrimary)
        } header: {
            Text("VENUE")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
        }
        .listRowBackground(Color.cardSurface)
    }

    private var financialsSection: some View {
        Section {
            numberField("Buy-in ($)", text: $buyIn)
            numberField("Entry Fee ($)", text: $entryFee)
            numberField("Bounty Amount ($)", text: $bountyAmount)
            numberField("Guarantee ($)", text: $guarantee)
            numberField("Payout % of Field", text: $payoutPercent)

            Picker("Re-entry Policy", selection: $reentryPolicy) {
                Text("None").tag("None")
                Text("1 Re-entry").tag("1 Re-entry")
                Text("2 Re-entries").tag("2 Re-entries")
                Text("Unlimited").tag("Unlimited")
            }
            .tint(.goldAccent)
        } header: {
            Text("FINANCIALS")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
        }
        .listRowBackground(Color.cardSurface)
    }

    private var structureSection: some View {
        Section {
            numberField("Starting Chips", text: $startingChips)
        } header: {
            Text("STARTING STACK")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
        }
        .listRowBackground(Color.cardSurface)
    }

    private var blindsSection: some View {
        Section {
            HStack {
                numberField("Starting SB", text: $startingSB)
                Text("/")
                    .foregroundColor(.textSecondary)
                numberField("Starting BB", text: $startingBB)
            }

            Button {
                // Create tournament first if needed, then open editor
                if tournament == nil && createdTournament == nil {
                    createdTournament = createTournament()
                }
                showBlindEditor = true
            } label: {
                HStack {
                    Image(systemName: "tablecells")
                    Text("Edit Full Blind Structure")
                    Spacer()
                    if !scannedBlindLevels.isEmpty {
                        Text("\(scannedBlindLevels.count) scanned")
                            .font(.caption)
                            .foregroundColor(.textSecondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
                .foregroundColor(.goldAccent)
            }

            if !scannedBlindLevels.isEmpty || (createdTournament ?? tournament)?.blindLevels.isEmpty == false {
                Button {
                    if tournament == nil && createdTournament == nil {
                        createdTournament = createTournament()
                    }
                    showScoutingReport = true
                } label: {
                    HStack {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text("View Scouting Report")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                    }
                    .foregroundColor(.goldAccent)
                }
            }
        } header: {
            Text("BLINDS")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
        }
        .listRowBackground(Color.cardSurface)
    }

    // MARK: - Helpers

    private func numberField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.textSecondary)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .foregroundColor(.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func loadExisting() {
        guard let tournament else { return }
        name = tournament.name
        gameType = tournament.gameType
        venueName = tournament.venueName ?? ""
        buyIn = tournament.buyIn > 0 ? "\(tournament.buyIn)" : ""
        entryFee = tournament.entryFee > 0 ? "\(tournament.entryFee)" : ""
        bountyAmount = tournament.bountyAmount > 0 ? "\(tournament.bountyAmount)" : ""
        guarantee = tournament.guarantee > 0 ? "\(tournament.guarantee)" : ""
        startingChips = "\(tournament.startingChips)"
        reentryPolicy = tournament.reentryPolicy
        payoutPercent = "\(Int(tournament.payoutPercent))"

        if let firstBlind = tournament.sortedBlindLevels.first {
            startingSB = "\(firstBlind.smallBlind)"
            startingBB = "\(firstBlind.bigBlind)"
        }
    }

    // MARK: - Scanning

    private func scanImages(_ images: [UIImage]) {
        isScanning = true
        Task {
            do {
                let result = try await PokerAtlasScanner.shared.scan(images: images)
                await MainActor.run {
                    applyScannedResult(result)
                    isScanning = false
                    HapticFeedback.success()
                }
            } catch {
                await MainActor.run {
                    scanError = error.localizedDescription
                    showingScanError = true
                    isScanning = false
                    HapticFeedback.error()
                }
            }
        }
    }

    private func applyScannedResult(_ result: PokerAtlasScanResult) {
        if let scannedName = result.tournamentName, !scannedName.isEmpty {
            name = scannedName
        }
        if let scannedVenue = result.venueName, !scannedVenue.isEmpty {
            venueName = scannedVenue
        }
        // Auto-enable sharing when populated from scan/browse (data is already public)
        if result.tournamentName != nil && result.venueName != nil {
            shareToCloudKit = true
        }
        if let scannedGameType = result.gameType {
            gameType = scannedGameType
        }
        if let scannedBuyIn = result.buyIn, scannedBuyIn > 0 {
            buyIn = "\(scannedBuyIn)"
        }
        if let scannedEntryFee = result.entryFee, scannedEntryFee > 0 {
            entryFee = "\(scannedEntryFee)"
        }
        if let scannedBounty = result.bountyAmount, scannedBounty > 0 {
            bountyAmount = "\(scannedBounty)"
        }
        if let scannedGuarantee = result.guarantee, scannedGuarantee > 0 {
            guarantee = "\(scannedGuarantee)"
        }
        if let scannedChips = result.startingChips, scannedChips > 0 {
            startingChips = "\(scannedChips)"
        }
        if let scannedReentry = result.reentryPolicy, !scannedReentry.isEmpty {
            reentryPolicy = scannedReentry
        }
        // Starting blinds from explicit "Starting Blinds" field
        if let sb = result.startingSB, sb > 0 {
            startingSB = "\(sb)"
        }
        if let bb = result.startingBB, bb > 0 {
            startingBB = "\(bb)"
        }
        // Blind levels override starting blinds with first level values
        if !result.blindLevels.isEmpty {
            scannedBlindLevels = result.blindLevels
            if let first = result.blindLevels.first(where: { !$0.isBreak }) {
                startingSB = "\(first.smallBlind)"
                startingBB = "\(first.bigBlind)"
            }
        }
    }

    private func createTournament() -> Tournament {
        let t = Tournament(
            name: name.trimmingCharacters(in: .whitespaces),
            gameType: gameType,
            buyIn: Int(buyIn) ?? 0,
            entryFee: Int(entryFee) ?? 0,
            bountyAmount: Int(bountyAmount) ?? 0,
            guarantee: Int(guarantee) ?? 0,
            startingChips: Int(startingChips) ?? 20000,
            reentryPolicy: reentryPolicy
        )
        t.venueName = venueName.isEmpty ? nil : venueName
        t.payoutPercent = Double(payoutPercent) ?? 15.0
        modelContext.insert(t)

        if !scannedBlindLevels.isEmpty {
            // Add all scanned blind levels via inverse relationship
            for scanned in scannedBlindLevels {
                let level = BlindLevel(
                    levelNumber: scanned.levelNumber,
                    smallBlind: scanned.smallBlind,
                    bigBlind: scanned.bigBlind,
                    ante: scanned.ante,
                    durationMinutes: scanned.durationMinutes,
                    isBreak: scanned.isBreak,
                    breakLabel: scanned.breakLabel
                )
                level.tournament = t
                modelContext.insert(level)
            }
        } else {
            // Add starting blind level
            let level1 = BlindLevel(
                levelNumber: 1,
                smallBlind: Int(startingSB) ?? 100,
                bigBlind: Int(startingBB) ?? 200
            )
            level1.tournament = t
            modelContext.insert(level1)
        }

        return t
    }

    private func startTournament() {
        let t: Tournament
        if let existing = tournament ?? createdTournament {
            // Update existing
            existing.name = name.trimmingCharacters(in: .whitespaces)
            existing.gameType = gameType
            existing.buyIn = Int(buyIn) ?? 0
            existing.entryFee = Int(entryFee) ?? 0
            existing.bountyAmount = Int(bountyAmount) ?? 0
            existing.guarantee = Int(guarantee) ?? 0
            existing.startingChips = Int(startingChips) ?? 20000
            existing.reentryPolicy = reentryPolicy
            existing.venueName = venueName.isEmpty ? nil : venueName
            existing.payoutPercent = Double(payoutPercent) ?? 15.0
            t = existing
        } else {
            t = createTournament()
        }

        tournamentManager.startTournament(t)
        HapticFeedback.success()

        if shareToCloudKit {
            let scanResult = buildCurrentScanResult()
            let venue = venueName
            Task {
                do {
                    let location: CLLocation
                    if let geocoded = await LocationManager.shared.geocodeVenue(
                        name: venue,
                        city: "",
                        state: ""
                    ) {
                        location = geocoded
                    } else if let userLoc = try? await LocationManager.shared.requestLocationOnce() {
                        location = userLoc
                    } else {
                        return
                    }
                    try await CloudKitService.shared.saveTournament(
                        scanResult: scanResult,
                        eventDate: Date(),
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude,
                        venueCity: "",
                        venueState: ""
                    )
                } catch {
                    // Sharing is best-effort — silently handle errors
                }
            }
        }

        dismiss()
    }
}

#Preview {
    TournamentSetupView()
        .modelContainer(for: Tournament.self, inMemory: true)
        .environment(TournamentManager())
}
