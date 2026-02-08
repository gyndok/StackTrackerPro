import SwiftUI

struct TournamentMetricsView: View {
    @Environment(TournamentManager.self) private var tournamentManager
    @Bindable var tournament: Tournament

    @State private var showStackEditor = false
    @State private var showPlayersEditor = false

    // Stack editor state
    @State private var editChipCount = ""
    @State private var editBlindLevel = 1

    // Players editor state
    @State private var editTotalEntries = ""
    @State private var editPlayersRemaining = ""

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
            }

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
            }
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

            // Total Investment
            StatBlockView(
                label: "Total Investment",
                value: formatCurrency(tournament.totalInvestment)
            )
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

    // MARK: - Save Actions

    private func saveStackEdit() {
        guard let chips = Int(editChipCount), chips > 0 else { return }
        tournamentManager.updateBlinds(levelNumber: editBlindLevel)
        tournamentManager.updateStack(chipCount: chips)
        HapticFeedback.success()
        showStackEditor = false
    }

    private func savePlayersEdit() {
        let entries = Int(editTotalEntries) ?? 0
        let remaining = Int(editPlayersRemaining) ?? 0

        guard remaining <= entries || entries == 0 else { return }
        guard entries == 0 || entries >= tournament.fieldSize else { return }

        tournamentManager.updateField(
            totalEntries: entries > 0 ? entries : nil,
            playersRemaining: remaining > 0 ? remaining : nil
        )
        HapticFeedback.success()
        showPlayersEditor = false
    }

    private var isPlayersEditValid: Bool {
        let entries = Int(editTotalEntries) ?? 0
        let remaining = Int(editPlayersRemaining) ?? 0
        if entries == 0 && remaining == 0 { return false }
        if entries > 0 && remaining > entries { return false }
        if entries > 0 && entries < tournament.fieldSize { return false }
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
        let snapshots = tournament.fieldSnapshots.sorted { $0.timestamp < $1.timestamp }
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

#Preview {
    TournamentMetricsView(tournament: Tournament(name: "Preview", buyIn: 150, entryFee: 30, guarantee: 50000, startingChips: 20000))
        .environment(TournamentManager())
        .background(Color.backgroundPrimary)
}
