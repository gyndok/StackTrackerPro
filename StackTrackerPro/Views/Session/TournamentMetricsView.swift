import SwiftUI
import SwiftData

struct TournamentMetricsView: View {
    @Environment(TournamentManager.self) private var tournamentManager
    @Environment(\.modelContext) private var modelContext
    @Bindable var tournament: Tournament

    @State private var showStackEditor = false
    @State private var showPlayersEditor = false

    // Buy-in editor state
    @State private var showBuyInEditor = false
    @State private var buyInSplit = BuyInSplit(total: 0, fee: 0)

    // Stack editor state
    @State private var editChipCount = ""
    @State private var editBlindLevel = 1

    // Players editor state
    @State private var editTotalEntries = ""
    @State private var editPlayersRemaining = ""

    // Add-on editor state
    @State private var showAddOnEditor = false
    @State private var editAddOnsCount = ""
    @State private var editPlayerAddOns = ""

    // Starting stack editor state
    @State private var showStartingStackEditor = false
    @State private var editStartingChips = ""

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                payoutEditor
                metricsGrid
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $showStackEditor) {
            stackEditorSheet
        }
        .sheet(isPresented: $showPlayersEditor) {
            playersEditorSheet
        }
        .sheet(isPresented: $showAddOnEditor) {
            addOnEditorSheet
        }
        .sheet(isPresented: $showStartingStackEditor) {
            startingStackEditorSheet
        }
        .sheet(isPresented: $showBuyInEditor) {
            buyInEditorSheet
        }
    }

    // MARK: - Payout % Editor

    private var payoutEditor: some View {
        HStack(spacing: 12) {
            Text("Payout %")
                .font(PokerTypography.chipLabel)
                .foregroundColor(.textSecondary)

            Spacer()

            Button {
                if tournament.payoutPercent > 0.5 {
                    tournament.payoutPercent -= 0.5
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
                    .foregroundColor(.goldAccent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Decrease payout percent")

            Text(String(format: tournament.payoutPercent.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f%%" : "%.1f%%", tournament.payoutPercent))
                .font(PokerTypography.statValue)
                .foregroundColor(.textPrimary)
                .frame(minWidth: 52, alignment: .center)

            Button {
                if tournament.payoutPercent < 100 {
                    tournament.payoutPercent += 0.5
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundColor(.goldAccent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Increase payout percent")
        }
        .padding(12)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Metrics Grid

    private var metricsGrid: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            // Players Left (editable)
            StatBlockView(
                label: "Players Left",
                value: playersDisplayValue,
                trend: playersTrend,
                isEditable: true,
                onTap: {
                    editTotalEntries = tournament.fieldSize > 0 ? "\(tournament.fieldSize)" : ""
                    editPlayersRemaining = tournament.playersRemaining > 0 ? "\(tournament.playersRemaining)" : ""
                    showPlayersEditor = true
                }
            )

            // Stack (editable)
            StatBlockView(
                label: "Stack",
                value: tournament.latestStack?.formattedChipCount ?? "---",
                valueColor: tournament.latestStack?.mZone.color ?? .textPrimary,
                isEditable: true,
                onTap: {
                    editChipCount = tournament.latestStack != nil ? "\(tournament.latestStack!.chipCount)" : ""
                    editBlindLevel = tournament.currentBlindLevelNumber
                    showStackEditor = true
                }
            )

            // Stack (BB)
            StatBlockView(
                label: "Stack (BB)",
                value: tournament.currentBBCount > 0
                    ? String(format: "%.1f", tournament.currentBBCount)
                    : "---",
                valueColor: tournament.latestStack?.mZone.color ?? .textPrimary
            )

            // Avg Stack
            StatBlockView(
                label: "Avg Stack",
                value: tournament.averageStack > 0
                    ? formatChipsShort(tournament.averageStack)
                    : "---"
            )

            // Avg Stack (BB)
            StatBlockView(
                label: "Avg Stack (BB)",
                value: tournament.averageStackInBB > 0
                    ? String(format: "%.1f", tournament.averageStackInBB)
                    : "---"
            )

            // Prize Pool
            StatBlockView(
                label: "Prize Pool",
                value: tournament.fieldSize > 0
                    ? formatCurrency(tournament.prizePool)
                    : "---"
            )

            // Overlay
            StatBlockView(
                label: "Overlay",
                value: overlayDisplayValue
            )

            // Players for GTD
            StatBlockView(
                label: "Players for GTD",
                value: playersForGTDDisplayValue
            )

            // To Bubble
            StatBlockView(
                label: "To Bubble",
                value: bubbleDisplayValue
            )

            // Avg Stack @ Bubble (projected)
            StatBlockView(
                label: "Avg @ Bubble",
                value: bubbleAvgStackDisplayValue
            )

            // Avg Stack @ 9-handed Final Table (projected)
            StatBlockView(
                label: "Avg @ FT (9)",
                value: finalTableAvgStackDisplayValue
            )

            // House Rake
            StatBlockView(
                label: "House Rake",
                value: tournament.fieldSize > 0
                    ? formatCurrency(tournament.houseRake)
                    : "---"
            )

            // Total Chips
            StatBlockView(
                label: "Total Chips",
                value: tournament.fieldSize > 0
                    ? formatNumber(tournament.totalChipsInPlay)
                    : "---"
            )

            // Total Investment (editable — works even after the tournament is
            // completed, since correcting a mis-recorded buy-in split is the
            // whole point of this editor; see saveBuyInEdit for why this
            // bypasses TournamentManager's usual live-session gating).
            StatBlockView(
                label: "Total Investment",
                value: formatCurrency(tournament.totalInvestment),
                isEditable: true,
                onTap: {
                    buyInSplit = BuyInSplit(total: tournament.buyIn, fee: tournament.entryFee)
                    showBuyInEditor = true
                }
            )

            // Starting Stack (editable — a wrong value poisons all chip math)
            StatBlockView(
                label: "Starting Stack",
                value: formatChipsShort(tournament.startingChips),
                isEditable: true,
                onTap: {
                    editStartingChips = "\(tournament.startingChips)"
                    showStartingStackEditor = true
                }
            )

            // Add-Ons (editable) — only when the tournament offers an add-on
            if tournament.addOnAvailable {
                StatBlockView(
                    label: "Add-Ons",
                    value: addOnsDisplayValue,
                    isEditable: true,
                    onTap: {
                        editAddOnsCount = tournament.addOnsCount > 0 ? "\(tournament.addOnsCount)" : ""
                        editPlayerAddOns = tournament.playerAddOnsUsed > 0 ? "\(tournament.playerAddOnsUsed)" : ""
                        showAddOnEditor = true
                    }
                )
            }
        }
    }

    // MARK: - Stack Editor Sheet

    private var stackEditorSheet: some View {
        NavigationStack {
            Form {
                Section("Chip Count") {
                    TextField("Chips", text: $editChipCount)
                        .keyboardType(.numberPad)
                }

                Section("Blind Level") {
                    if tournament.sortedBlindLevels.isEmpty {
                        Text("No blind levels configured")
                            .foregroundColor(.textSecondary)
                    } else {
                        Picker("Level", selection: $editBlindLevel) {
                            ForEach(tournament.sortedBlindLevels.filter { !$0.isBreak }, id: \.levelNumber) { level in
                                let displayNum = tournament.displayLevelNumbers[level.levelNumber] ?? level.levelNumber
                                Text("Lvl \(displayNum) — \(level.blindsDisplay)")
                                    .tag(level.levelNumber)
                            }
                        }
                        .pickerStyle(.wheel)
                    }
                }
            }
            .navigationTitle("Edit Stack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showStackEditor = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveStackEdit()
                    }
                    .disabled(Int(editChipCount) == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Players Editor Sheet

    private var playersEditorSheet: some View {
        NavigationStack {
            Form {
                Section("Total Entries") {
                    TextField("Total entries", text: $editTotalEntries)
                        .keyboardType(.numberPad)
                }

                Section("Players Remaining") {
                    TextField("Players remaining", text: $editPlayersRemaining)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle("Edit Players")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showPlayersEditor = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        savePlayersEdit()
                    }
                    .disabled(!isPlayersEditValid)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Add-On Editor Sheet

    private var addOnEditorSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Add-ons taken", text: $editAddOnsCount)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Field Add-Ons")
                } footer: {
                    Text("Total add-ons taken across the field. Each adds \(formatChipsShort(tournament.addOnChips)) chips and \(formatCurrency(tournament.addOnToPrizePool)) to the prize pool.")
                }

                Section {
                    TextField("My add-ons", text: $editPlayerAddOns)
                        .keyboardType(.numberPad)
                } header: {
                    Text("My Add-Ons")
                } footer: {
                    Text("Add-ons you took. Each adds \(formatCurrency(tournament.addOnCost)) to your investment. Update your stack separately.")
                }
            }
            .navigationTitle("Edit Add-Ons")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showAddOnEditor = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAddOnEdit()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Starting Stack Editor Sheet

    private var startingStackEditorSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Chips", text: $editStartingChips)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Starting Stack")
                } footer: {
                    Text("Corrects the stack every player started with. Total chips, average stacks, and the bubble/final-table projections all recalculate from this.")
                }
            }
            .navigationTitle("Edit Starting Stack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showStartingStackEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveStartingStackEdit() }
                        .disabled((Int(editStartingChips) ?? 0) <= 0)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Buy-In Editor Sheet

    private var buyInEditorSheet: some View {
        BuyInEditSheet(
            split: $buyInSplit,
            tournament: tournament,
            onCancel: { showBuyInEditor = false },
            onSave: { saveBuyInEdit() }
        )
    }

    // MARK: - Save Actions

    // Writes directly to the model (bypassing TournamentManager's
    // mutableTournament gating, which no-ops on completed tournaments) because
    // correcting a mis-recorded buy-in split after the fact — the exact bug
    // this editor exists to fix — must work for completed sessions too.
    private func saveBuyInEdit() {
        tournament.buyIn = buyInSplit.total
        tournament.entryFee = buyInSplit.fee
        try? modelContext.save()
        HapticFeedback.success()
        showBuyInEditor = false
    }

    private func saveStartingStackEdit() {
        guard let chips = Int(editStartingChips), chips > 0 else { return }
        tournamentManager.updateStartingChips(chips)
        HapticFeedback.success()
        showStartingStackEditor = false
    }

    private func saveAddOnEdit() {
        tournamentManager.updateAddOns(
            fieldCount: Int(editAddOnsCount) ?? 0,
            playerCount: Int(editPlayerAddOns) ?? 0
        )
        HapticFeedback.success()
        showAddOnEditor = false
    }

    private func saveStackEdit() {
        guard let chips = Int(editChipCount), chips > 0 else { return }
        tournamentManager.updateBlinds(levelNumber: editBlindLevel)
        tournamentManager.updateStack(chipCount: chips)
        HapticFeedback.success()
        showStackEditor = false
    }

    private func savePlayersEdit() {
        guard isPlayersEditValid else { return }
        let entries = Int(editTotalEntries) ?? 0
        let remaining = Int(editPlayersRemaining) ?? 0

        tournamentManager.updateField(
            totalEntries: entries > 0 ? entries : nil,
            playersRemaining: remaining > 0 ? remaining : nil
        )
        HapticFeedback.success()
        showPlayersEditor = false
    }

    // Any positive entry count is allowed (so a fat-fingered field size can be
    // corrected downward) — it just can't drop below the players still in.
    private var isPlayersEditValid: Bool {
        let entries = Int(editTotalEntries) ?? 0
        let remaining = Int(editPlayersRemaining) ?? 0
        if entries == 0 && remaining == 0 { return false }
        let effectiveRemaining = remaining > 0 ? remaining : tournament.playersRemaining
        if entries > 0 && entries < effectiveRemaining { return false }
        return true
    }

    // MARK: - Display Values

    private var playersDisplayValue: String {
        let remaining = tournament.playersRemaining
        let field = tournament.fieldSize
        if remaining > 0 && field > 0 {
            return "\(remaining) / \(field)"
        } else if remaining > 0 {
            return "\(remaining)"
        }
        return "---"
    }

    private var playersTrend: TrendDirection? {
        let snapshots = (tournament.fieldSnapshots ?? []).sorted { $0.timestamp < $1.timestamp }
        guard snapshots.count >= 2 else { return nil }
        let last = snapshots[snapshots.count - 1].playersRemaining
        let prev = snapshots[snapshots.count - 2].playersRemaining
        if last < prev { return .down }
        if last > prev { return .up }
        return .flat
    }

    private var overlayDisplayValue: String {
        guard tournament.guarantee > 0 else { return "---" }
        guard tournament.fieldSize > 0 else { return "---" }
        let amount = tournament.overlay
        return amount > 0 ? formatCurrency(amount) : "None"
    }

    private var playersForGTDDisplayValue: String {
        guard tournament.guarantee > 0 else { return "---" }
        guard tournament.fieldSize > 0 else { return "---" }
        let needed = tournament.playersNeededForGuarantee
        return needed > 0 ? "\(needed)" : "Met"
    }

    private var bubbleDisplayValue: String {
        guard tournament.fieldSize > 0, tournament.payoutPercent > 0 else { return "---" }
        guard tournament.playersRemaining > 0 else { return "---" }
        let paid = Int(ceil(Double(tournament.fieldSize) * tournament.payoutPercent / 100.0))
        let distance = tournament.estimatedBubbleDistance
        if distance > 0 {
            return "\(distance) (\(paid) paid)"
        }
        return "ITM! (\(paid) paid)"
    }

    // Projected average stack at the moment the money bubble bursts.
    private var bubbleAvgStackDisplayValue: String {
        guard tournament.fieldSize > 0, tournament.payoutPercent > 0 else { return "---" }
        let avg = tournament.averageStackAtBubble
        guard avg > 0 else { return "---" }
        return formatChipsShort(avg)
    }

    // Projected average stack at a 9-handed final table.
    private var finalTableAvgStackDisplayValue: String {
        let avg = tournament.averageStackAtFinalTable
        guard avg > 0 else { return "---" }
        return formatChipsShort(avg)
    }

    // Field add-on count, with the player's own add-ons noted when taken.
    private var addOnsDisplayValue: String {
        let field = tournament.addOnsCount
        let mine = tournament.playerAddOnsUsed
        if field == 0 && mine == 0 { return "---" }
        return mine > 0 ? "\(field) (\(mine) me)" : "\(field)"
    }

    // MARK: - Formatters

    private func formatCurrency(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 0
        formatter.currencySymbol = "$"
        return formatter.string(from: NSNumber(value: value)) ?? "$\(value)"
    }

    private func formatChipsShort(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.0fM", Double(value) / 1_000_000)
        } else if value >= 1000 {
            return String(format: "%.0fk", Double(value) / 1000)
        }
        return "\(value)"
    }

    private func formatNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - BuyInSplit

/// Pure rebalance rule for the buy-in editor. Total = prizePool + fee,
/// maintained live as the user edits any one of the three fields. All Ints,
/// never negative.
struct BuyInSplit: Equatable {
    var total: Int
    var fee: Int

    var prizePool: Int { max(0, total - fee) }

    /// User edited the total: keep the fee (clamped to no more than the new
    /// total), let the prize pool absorb the difference.
    mutating func setTotal(_ v: Int) {
        total = max(0, v)
        fee = min(fee, total)
    }

    /// User edited the prize-pool share: keep the fee, total follows.
    mutating func setPrizePool(_ v: Int) {
        let clampedPrize = max(0, v)
        total = clampedPrize + fee
    }

    /// User edited the house fee: keep the prize-pool share, total follows.
    mutating func setFee(_ v: Int) {
        let currentPrize = prizePool
        fee = max(0, v)
        total = currentPrize + fee
    }
}

// MARK: - BuyInEditSheet

/// Field being actively edited, so a programmatic rebalance of the other two
/// fields never fights the user's own typing (which would otherwise ping-pong
/// via onChange since all three fields are derived from the same struct).
private enum BuyInField: Hashable {
    case total, prizePool, fee
}

/// Three-field editor for `Tournament.buyIn` / `entryFee`, expressed as
/// Total buy-in / To prize pool / House fee, live-rebalanced through
/// `BuyInSplit`. `onSave` is expected to write `split.total`/`split.fee`
/// back onto the tournament.
private struct BuyInEditSheet: View {
    @Binding var split: BuyInSplit
    let tournament: Tournament
    let onCancel: () -> Void
    let onSave: () -> Void

    @State private var totalText = ""
    @State private var prizeText = ""
    @State private var feeText = ""
    @FocusState private var focusedField: BuyInField?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Total buy-in", text: $totalText)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .total)
                        .onChange(of: totalText) { _, newValue in
                            guard focusedField == .total else { return }
                            split.setTotal(Int(newValue) ?? 0)
                            syncOtherFields()
                        }
                } header: {
                    Text("Total Buy-In")
                } footer: {
                    Text("What one entry costs you.")
                }

                Section {
                    TextField("To prize pool", text: $prizeText)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .prizePool)
                        .onChange(of: prizeText) { _, newValue in
                            guard focusedField == .prizePool else { return }
                            split.setPrizePool(Int(newValue) ?? 0)
                            syncOtherFields()
                        }
                } header: {
                    Text("To Prize Pool")
                }

                Section {
                    TextField("House fee", text: $feeText)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .fee)
                        .onChange(of: feeText) { _, newValue in
                            guard focusedField == .fee else { return }
                            split.setFee(Int(newValue) ?? 0)
                            syncOtherFields()
                        }
                } header: {
                    Text("House Fee")
                } footer: {
                    if tournament.bountyAmount > 0 || tournament.deductions > 0 {
                        Text("Prize-pool math also subtracts your bounty (\(formatCurrency(tournament.bountyAmount))) and deductions (\(formatCurrency(tournament.deductions))).")
                    }
                }
            }
            .navigationTitle("Edit Buy-In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            totalText = "\(split.total)"
            prizeText = "\(split.prizePool)"
            feeText = "\(split.fee)"
        }
    }

    // Refreshes the display text of every field except the one currently
    // focused, so the user's in-progress typing/cursor is never clobbered.
    private func syncOtherFields() {
        if focusedField != .total { totalText = "\(split.total)" }
        if focusedField != .prizePool { prizeText = "\(split.prizePool)" }
        if focusedField != .fee { feeText = "\(split.fee)" }
    }

    private func formatCurrency(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 0
        formatter.currencySymbol = "$"
        return formatter.string(from: NSNumber(value: value)) ?? "$\(value)"
    }
}

#Preview {
    TournamentMetricsView(tournament: Tournament(name: "Preview", buyIn: 150, entryFee: 30, guarantee: 50000, startingChips: 20000))
        .environment(TournamentManager())
        .background(Color.backgroundPrimary)
}
