import SwiftUI
import SwiftData
import PhotosUI
import CoreLocation
import PDFKit
import UniformTypeIdentifiers
import os

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
    @State private var gameTypeRaw: String = GameType.nlh.rawValue
    @State private var venueName = ""
    @State private var buyIn = ""
    @State private var entryFee = ""
    @State private var deductions = ""
    @State private var bountyAmount = ""
    @State private var guarantee = ""
    @State private var startingChips = "20000"
    @State private var startingSB = "100"
    @State private var startingBB = "200"
    @State private var reentryPolicy = "None"
    @State private var payoutPercent = "15"
    @State private var addOnAvailable = false
    @State private var addOnCost = ""
    @State private var addOnRake = ""
    @State private var addOnChips = ""
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
    @State private var showingStructureLibrary = false
    @State private var showingPDFImporter = false

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
                    addOnSection
                    blindsSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(tournament == nil ? "New Tournament" : "Edit Tournament")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Discard the tournament created for the blind editor /
                        // scouting report if the user never started it.
                        if let created = createdTournament {
                            modelContext.delete(created)
                            createdTournament = nil
                        }
                        dismiss()
                    }
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
                    BlindStructureEditorView(tournament: t, scannedLevels: $scannedBlindLevels)
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
            .sheet(isPresented: $showingStructureLibrary) {
                StructureLibraryView { template in
                    applyLibraryTemplate(template)
                }
            }
            .fileImporter(
                isPresented: $showingPDFImporter,
                allowedContentTypes: [UTType.pdf]
            ) { result in
                switch result {
                case .success(let url):
                    importStructurePDF(from: url)
                case .failure(let error):
                    scanError = error.localizedDescription
                    showingScanError = true
                }
            }
            .onAppear {
                if tournament != nil {
                    loadExisting()
                } else {
                    gameTypeRaw = savedGameType
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
        result.gameType = GameType(rawValue: gameTypeRaw)
        result.buyIn = Int(buyIn)
        result.entryFee = Int(entryFee)
        result.deductions = Int(deductions)
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
                showingPDFImporter = true
            } label: {
                HStack {
                    Image(systemName: "doc.viewfinder")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Import Structure PDF")
                            .fontWeight(.semibold)
                        Text("WSOP and venue structure sheets from Files")
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
                showingStructureLibrary = true
            } label: {
                HStack {
                    Image(systemName: "books.vertical")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Load from Library")
                            .fontWeight(.semibold)
                        Text("Reuse a saved blind structure")
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

            GameTypePickerView(selectedRawValue: $gameTypeRaw)
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
            numberField("Deductions ($)", text: $deductions)
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

    private var addOnSection: some View {
        Section {
            Toggle("Add-On Available", isOn: $addOnAvailable)
                .tint(.goldAccent)
                .foregroundColor(.textSecondary)

            if addOnAvailable {
                numberField("Cost ($)", text: $addOnCost)
                numberField("House Rake ($)", text: $addOnRake)
                numberField("Chips", text: $addOnChips)

                HStack {
                    Text("To Prize Pool")
                        .foregroundColor(.textSecondary)
                    Spacer()
                    Text("$\(addOnToPrizePoolPreview)")
                        .foregroundColor(.goldAccent)
                }
            }
        } header: {
            Text("ADD-ON")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
        }
        .listRowBackground(Color.cardSurface)
    }

    /// Live preview of the per-add-on prize-pool contribution (cost − rake).
    private var addOnToPrizePoolPreview: Int {
        max(0, (Int(addOnCost) ?? 0) - (Int(addOnRake) ?? 0))
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

            if !scannedBlindLevels.isEmpty || (createdTournament ?? tournament)?.blindLevels?.isEmpty == false {
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

    /// Writes the add-on configuration onto a tournament. When the add-on is
    /// turned off, the related fields are zeroed so stale values can't leak
    /// into the prize-pool/chip math.
    private func applyAddOnFields(to t: Tournament) {
        t.addOnAvailable = addOnAvailable
        if addOnAvailable {
            t.addOnCost = Int(addOnCost) ?? 0
            t.addOnRake = Int(addOnRake) ?? 0
            t.addOnChips = Int(addOnChips) ?? 0
        } else {
            t.addOnCost = 0
            t.addOnRake = 0
            t.addOnChips = 0
            t.addOnsCount = 0
            t.playerAddOnsUsed = 0
        }
    }

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
        gameTypeRaw = tournament.gameTypeRaw
        venueName = tournament.venueName ?? ""
        buyIn = tournament.buyIn > 0 ? "\(tournament.buyIn)" : ""
        entryFee = tournament.entryFee > 0 ? "\(tournament.entryFee)" : ""
        deductions = tournament.deductions > 0 ? "\(tournament.deductions)" : ""
        bountyAmount = tournament.bountyAmount > 0 ? "\(tournament.bountyAmount)" : ""
        guarantee = tournament.guarantee > 0 ? "\(tournament.guarantee)" : ""
        startingChips = "\(tournament.startingChips)"
        reentryPolicy = tournament.reentryPolicy
        payoutPercent = "\(Int(tournament.payoutPercent))"
        addOnAvailable = tournament.addOnAvailable
        addOnCost = tournament.addOnCost > 0 ? "\(tournament.addOnCost)" : ""
        addOnRake = tournament.addOnRake > 0 ? "\(tournament.addOnRake)" : ""
        addOnChips = tournament.addOnChips > 0 ? "\(tournament.addOnChips)" : ""

        if let firstBlind = tournament.sortedBlindLevels.first {
            startingSB = "\(firstBlind.smallBlind)"
            startingBB = "\(firstBlind.bigBlind)"
        }
    }

    // MARK: - Structure Library

    /// Applies a saved library structure the same way a successful scan does:
    /// the levels flow through `scannedBlindLevels` into the create/update
    /// path and the blind editor.
    private func applyLibraryTemplate(_ template: BlindStructureTemplate) {
        scannedBlindLevels = template.levels.map { $0.toScannedBlindLevel() }
        if template.startingChips > 0 {
            startingChips = "\(template.startingChips)"
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            name = template.name
        }
        if venueName.trimmingCharacters(in: .whitespaces).isEmpty,
           let venue = template.venueName {
            venueName = venue
        }
        HapticFeedback.success()
    }

    // MARK: - PDF Import

    /// Renders the first pages of a structure PDF (WSOP sheets etc.) at high
    /// resolution and feeds them through the existing OCR scan pipeline —
    /// clean full-page renders OCR far better than screenshots of a PDF.
    private func importStructurePDF(from url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            scanError = "Couldn't open that PDF."
            showingScanError = true
            return
        }

        // Structure sheets are short; 6 pages covers any of them while
        // bounding render + OCR time.
        let pageLimit = min(document.pageCount, 6)
        var images: [UIImage] = []
        for index in 0..<pageLimit {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            // ~3x scale ≈ 216 DPI for a US-letter sheet — plenty for OCR.
            let scale: CGFloat = 3.0
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            images.append(page.thumbnail(of: size, for: .mediaBox))
        }

        guard !images.isEmpty else {
            scanError = "Couldn't render any pages from that PDF."
            showingScanError = true
            return
        }

        scanImages(images)
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
            gameTypeRaw = scannedGameType.rawValue
        }
        if let scannedBuyIn = result.buyIn, scannedBuyIn > 0 {
            buyIn = "\(scannedBuyIn)"
        }
        if let scannedEntryFee = result.entryFee, scannedEntryFee > 0 {
            entryFee = "\(scannedEntryFee)"
        }
        if let scannedDeductions = result.deductions, scannedDeductions > 0 {
            deductions = "\(scannedDeductions)"
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
            buyIn: Int(buyIn) ?? 0,
            entryFee: Int(entryFee) ?? 0,
            bountyAmount: Int(bountyAmount) ?? 0,
            guarantee: Int(guarantee) ?? 0,
            startingChips: Int(startingChips) ?? 20000,
            reentryPolicy: reentryPolicy
        )
        t.gameTypeRaw = gameTypeRaw
        t.venueName = venueName.isEmpty ? nil : venueName
        t.payoutPercent = Double(payoutPercent) ?? 15.0
        t.deductions = Int(deductions) ?? 0
        applyAddOnFields(to: t)
        modelContext.insert(t)

        if !scannedBlindLevels.isEmpty {
            applyScannedBlindLevels(to: t)
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

    /// Replaces the tournament's blind levels with the scanned ones, deleting
    /// the old BlindLevel objects from the context. `scannedBlindLevels` is
    /// left intact so the CloudKit share payload can still include it; the
    /// blind editor consumes it through its binding instead.
    private func applyScannedBlindLevels(to t: Tournament) {
        guard !scannedBlindLevels.isEmpty else { return }

        for existing in t.blindLevels ?? [] {
            modelContext.delete(existing)
        }
        t.blindLevels?.removeAll()

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
    }

    private func startTournament() {
        let t: Tournament
        if let existing = tournament ?? createdTournament {
            // Update existing
            existing.name = name.trimmingCharacters(in: .whitespaces)
            existing.gameTypeRaw = gameTypeRaw
            existing.buyIn = Int(buyIn) ?? 0
            existing.entryFee = Int(entryFee) ?? 0
            existing.deductions = Int(deductions) ?? 0
            existing.bountyAmount = Int(bountyAmount) ?? 0
            existing.guarantee = Int(guarantee) ?? 0
            existing.startingChips = Int(startingChips) ?? 20000
            existing.reentryPolicy = reentryPolicy
            existing.venueName = venueName.isEmpty ? nil : venueName
            existing.payoutPercent = Double(payoutPercent) ?? 15.0
            applyAddOnFields(to: existing)
            applyScannedBlindLevels(to: existing)
            t = existing
        } else {
            t = createTournament()
        }

        tournamentManager.startTournament(t)
        HapticFeedback.success()

        if shareToCloudKit {
            let scanResult = buildCurrentScanResult()
            let venue = venueName
            // Prefer the saved venue's city/state so multi-location chains
            // ("Texas Card House") geocode to the right city. Looked up here,
            // before dismiss, so the Task never touches the model context.
            let savedVenue = (try? modelContext.fetch(FetchDescriptor<Venue>()))?
                .first { $0.name.localizedCaseInsensitiveCompare(venue) == .orderedSame }
            let venueCity = savedVenue?.city ?? ""
            let venueState = savedVenue?.state ?? ""
            Task {
                let logger = Logger(subsystem: "com.gyndok.stacktrackerpro", category: "CloudKitShare")
                do {
                    // The venue's coordinates drive the 50-mile nearby browser,
                    // so never substitute the sharer's current location — a
                    // wrong-city listing is worse than no listing.
                    guard let location = await LocationManager.shared.geocodeVenue(
                        name: venue,
                        city: venueCity,
                        state: venueState
                    ) else {
                        logger.notice("Tournament share skipped: could not geocode venue '\(venue, privacy: .public)'")
                        return
                    }
                    try await CloudKitService.shared.saveTournament(
                        scanResult: scanResult,
                        eventDate: Date(),
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude,
                        venueCity: venueCity,
                        venueState: venueState
                    )
                    logger.info("Tournament shared to CloudKit public database")
                } catch CloudKitServiceError.duplicateSkipped {
                    logger.info("Tournament share skipped: duplicate already exists")
                } catch {
                    // Sharing is best-effort (the tournament still starts), but
                    // the failure must be diagnosable — a missing production
                    // schema shows up here as a CKError.
                    logger.error("Tournament share failed: \(error.localizedDescription, privacy: .public)")
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
