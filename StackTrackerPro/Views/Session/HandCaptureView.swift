import SwiftUI
import SwiftData

/// Full hand-capture screen (Hand Logging v2, Phase C). A single scrolling
/// surface driven entirely by `HandCaptureModel` — pot, turn order, street,
/// legal actions, and winners are all read from the engine. This view only
/// renders that state and forwards taps; it derives nothing about the hand
/// itself (the only local math is chip-input parsing and bet-sizing presets,
/// which are UI conveniences, not hand state).
struct HandCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(TournamentManager.self) private var tournamentManager

    let tournament: Tournament?
    let cashSession: CashSession?
    let stub: HandStub?
    let onSaved: (Hand) -> Void

    @State private var model: HandCaptureModel
    @AppStorage(SettingsKeys.defaultSeatsPerTable) private var seatsDefault = 9

    @State private var showCloseConfirm = false
    @State private var truncateIndex: Int?
    @State private var showPotPad = false
    @State private var potPadText = ""
    @State private var showStackPad = false
    @State private var stackPadText = ""
    @State private var villainEditorTarget: VillainEditorTarget?
    @State private var pendingActionType: HandActionType?

    init(tournament: Tournament?, cashSession: CashSession?, stub: HandStub?, onSaved: @escaping (Hand) -> Void) {
        self.tournament = tournament
        self.cashSession = cashSession
        self.stub = stub
        self.onSaved = onSaved

        let gameType = tournament?.gameType ?? cashSession?.gameType
        let cardCount = gameType == .plo ? 4 : 2

        if let stub {
            _model = State(initialValue: HandCaptureModel(stub: stub, heroCardCount: cardCount))
        } else if let tournament {
            let blinds = tournament.currentBlinds
            _model = State(initialValue: HandCaptureModel(
                levelNumber: tournament.currentBlindLevelNumber,
                smallBlind: blinds?.smallBlind ?? 0,
                bigBlind: blinds?.bigBlind ?? 0,
                ante: blinds?.ante ?? 0,
                heroCardCount: cardCount,
                heroStackBefore: tournament.latestStack?.chipCount ?? 0))
        } else {
            _model = State(initialValue: HandCaptureModel(
                levelNumber: 0, smallBlind: 0, bigBlind: 0, ante: 0,
                heroCardCount: cardCount,
                heroStackBefore: cashSession?.latestStack?.chipCount ?? 0))
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.backgroundPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        NarrationBar(model: model, showPotPad: $showPotPad, potPadText: $potPadText)
                        HeroStrip(model: model, stubHint: stubHint,
                                 showStackPad: $showStackPad, stackPadText: $stackPadText)
                        villainSection
                        LedgerList(model: model, truncateIndex: $truncateIndex)

                        if model.participantToAct != nil {
                            ActionRow(model: model, pendingActionType: $pendingActionType)
                        }
                        if let type = pendingActionType {
                            SizingRow(model: model, actionType: type,
                                     onCommit: commitSizedAction, onCancel: { pendingActionType = nil })
                        }
                        if model.boardCardsNeeded > 0 {
                            BoardEntry(model: model)
                        }
                        if model.isHandOver {
                            ResultBlock(model: model)
                            tagRow
                            saveButton
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Log Hand")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        if model.ledger.isEmpty { dismiss() } else { showCloseConfirm = true }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .foregroundColor(.textSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        model.undoLast()
                        pendingActionType = nil
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .foregroundColor(.goldAccent)
                    .disabled(model.ledger.isEmpty && model.board.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
        .confirmationDialog("Discard this hand?", isPresented: $showCloseConfirm, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .confirmationDialog(
            "Undo to this point? Later actions and board cards will be removed.",
            isPresented: Binding(get: { truncateIndex != nil }, set: { if !$0 { truncateIndex = nil } }),
            titleVisibility: .visible
        ) {
            Button("Undo to Here", role: .destructive) {
                if let index = truncateIndex { model.truncate(toLedgerIndex: index) }
                truncateIndex = nil
            }
            Button("Cancel", role: .cancel) { truncateIndex = nil }
        }
        .alert("Set Pot", isPresented: $showPotPad) {
            TextField("e.g. 390k", text: $potPadText).keyboardType(.numbersAndPunctuation)
            Button("Set") { model.potOverride = ChipInput.parse(potPadText) }
            Button("Clear", role: .destructive) { model.potOverride = nil }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Hero Stack Before Hand", isPresented: $showStackPad) {
            TextField("e.g. 390k", text: $stackPadText).keyboardType(.numbersAndPunctuation)
            Button("Set") {
                if let value = ChipInput.parse(stackPadText) { model.heroStackBefore = value }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Villain section

    private var villainSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Villains").font(PokerTypography.sectionHeader).foregroundColor(.goldAccent)
            ForEach(model.villains) { villain in
                HStack(spacing: 8) {
                    Button {
                        villainEditorTarget = villainEditorTarget == .editing(villain.id)
                            ? nil : .editing(villain.id)
                    } label: {
                        Text(villainChipText(villain))
                    }
                    .quickChip()
                    Spacer()
                    Button {
                        model.removeVillain(id: villain.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .foregroundColor(.chipRed)
                }
            }
            Button {
                villainEditorTarget = villainEditorTarget == .adding ? nil : .adding
            } label: {
                Label("Add Villain", systemImage: "plus.circle")
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(.goldAccent)
            }

            if let target = villainEditorTarget {
                VillainInlineEditor(model: model, editing: editing(for: target)) {
                    villainEditorTarget = nil
                }
            }
        }
        .pokerCard()
    }

    private func editing(for target: VillainEditorTarget) -> HandCaptureModel.VillainDraft? {
        guard case .editing(let id) = target else { return nil }
        return model.villains.first { $0.id == id }
    }

    private func villainChipText(_ villain: HandCaptureModel.VillainDraft) -> String {
        var text = model.label(for: .villain(villain.id))
        if villain.approxStack > 0 { text += " ≈\(villain.approxStack.formatted())" }
        if villain.shownHolding.count == 2 {
            text += " " + villain.shownHolding.map(\.display).joined(separator: " ")
        } else if villain.mucked {
            text += " (mucked)"
        }
        return text
    }

    // MARK: - Tags + Save

    private static let presetTags = ["Cooler", "Bluff", "Value", "Hero call", "Punt?"]

    private var tagRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags").font(PokerTypography.sectionHeader).foregroundColor(.goldAccent)
            HStack(spacing: 8) {
                ForEach(Self.presetTags, id: \.self) { tag in
                    let isOn = model.selectedTags.contains(tag)
                    Button(tag) {
                        if isOn { model.selectedTags.remove(tag) } else { model.selectedTags.insert(tag) }
                    }
                    .buttonStyle(.bordered)
                    .tint(isOn ? .goldAccent : .secondary)
                }
            }
        }
    }

    private var saveButton: some View {
        Button {
            save()
        } label: {
            Text("Save Hand")
        }
        .buttonStyle(PokerButtonStyle(isEnabled: canSave))
        .disabled(!canSave)
    }

    /// Save gates on the hand being over, and — at a real showdown — every
    /// still-live villain having either a shown two-card holding or an
    /// explicit muck, unless a manual `winnerOverride` already settles it.
    /// Without this the engine would silently compute a hero win against an
    /// unresolved villain.
    private var canSave: Bool {
        guard model.isHandOver else { return false }
        if !model.needsShowdown { return true }
        if model.winnerOverride != nil { return true }
        return model.villains.allSatisfy { villain in
            model.foldedParticipants.contains(.villain(villain.id))
                || villain.mucked || villain.shownHolding.count == 2
        }
    }

    private func commitSizedAction(_ type: HandActionType, _ amount: Int) {
        model.add(action: type, toAmount: amount)
        pendingActionType = nil
        HapticFeedback.impact(.medium)
    }

    private var stubHint: String? {
        guard let stub, !stub.holeCards.isEmpty, !HoleCardShorthand.isExact(stub.holeCards) else { return nil }
        return stub.holeCards
    }

    private func save() {
        let hand = model.save(into: modelContext, tournament: tournament, cashSession: cashSession,
                              sourceStub: stub, tableSize: seatsDefault)
        if tournament != nil, model.heroStackAfter > 0 {
            tournamentManager.updateStack(chipCount: model.heroStackAfter)
        }
        HapticFeedback.success()
        onSaved(hand)
        dismiss()
    }
}

// MARK: - Chip input parsing

/// Parses free-form chip amounts: "390k"/"42.5k" for thousands, "1.2m" for
/// millions, otherwise a bare integer. When `bigBlindMultiplier` is supplied
/// (bet-sizing entry only) a short bare number (<= 3 digits) is treated as a
/// multiple of the big blind, e.g. "3" -> 3 * bigBlind.
enum ChipInput {
    static func parse(_ raw: String, bigBlindMultiplier bigBlind: Int = 0) -> Int? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return nil }
        if cleaned.hasSuffix("k") {
            guard let num = Double(cleaned.dropLast()), num > 0 else { return nil }
            return Int((num * 1000).rounded())
        }
        if cleaned.hasSuffix("m") {
            guard let num = Double(cleaned.dropLast()), num > 0 else { return nil }
            return Int((num * 1_000_000).rounded())
        }
        guard let value = Int(cleaned), value >= 0 else { return nil }
        if bigBlind > 0, value > 0, cleaned.count <= 3 {
            return value * bigBlind
        }
        return value
    }
}

// MARK: - Position grid

/// Shared 3-column, 9-seat position picker used for both the hero's seat
/// (`HeroStrip`) and a villain's seat (`VillainInlineEditor`, which disables
/// whichever seat the hero already occupies).
private struct PositionGrid: View {
    let selected: HeroPosition?
    var disabled: (HeroPosition) -> Bool = { _ in false }
    let onSelect: (HeroPosition) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(HeroPosition.allCases, id: \.self) { position in
                let isDisabled = disabled(position)
                let isSelected = selected == position
                Button {
                    onSelect(position)
                } label: {
                    Text(position.rawValue)
                        .font(PokerTypography.chipLabel)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(isSelected ? Color.goldAccent : Color.backgroundPrimary)
                        .foregroundColor(isSelected ? .backgroundPrimary : .textPrimary)
                        .opacity(isDisabled ? 0.35 : 1)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(isDisabled)
            }
        }
    }
}

// MARK: - Narration bar

private struct NarrationBar: View {
    let model: HandCaptureModel
    @Binding var showPotPad: Bool
    @Binding var potPadText: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(model.narration)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                potPadText = String(model.pot)
                showPotPad = true
            } label: {
                Text("Pot \(model.pot.formatted())")
            }
            .quickChip()
        }
        .pokerCard()
    }
}

// MARK: - Hero strip

private struct HeroStrip: View {
    let model: HandCaptureModel
    let stubHint: String?
    @Binding var showStackPad: Bool
    @Binding var stackPadText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hero").font(PokerTypography.sectionHeader).foregroundColor(.goldAccent)

            PositionGrid(selected: model.heroPosition) { position in
                model.heroPosition = position
                HapticFeedback.impact(.light)
            }

            HStack(spacing: 8) {
                ForEach(model.heroCards, id: \.self) { card in
                    Text(card.display)
                        .font(PokerTypography.statValue)
                        .foregroundColor(card.isRed ? .red : .textPrimary)
                        .frame(width: 48, height: 60)
                        .background(Color.backgroundPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if model.heroCards.count < model.heroCardCount, let stubHint {
                    Text("Stub: \(stubHint)")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)
                }
                Spacer()
            }

            if model.heroCards.count < model.heroCardCount {
                CardPickerGrid(dealt: model.dealtCards) { card in
                    if model.addCard(card) { HapticFeedback.impact(.light) }
                }
            }

            HStack {
                Text("Stack").foregroundColor(.textSecondary)
                Spacer()
                Button {
                    stackPadText = String(model.heroStackBefore)
                    showStackPad = true
                } label: {
                    Text(model.heroStackBefore.formatted())
                        .font(PokerTypography.statValue)
                        .foregroundColor(.textPrimary)
                }
            }
        }
        .pokerCard()
    }
}

// MARK: - Villain editor

/// Which inline villain editor is expanded, if any: a fresh add, or an
/// existing villain re-opened for editing (tap position → tap relative-stack
/// commits immediately, matching the brief's "inline editor" — no modal, no
/// separate Save tap).
private enum VillainEditorTarget: Equatable {
    case adding
    case editing(UUID)
}

private struct VillainInlineEditor: View {
    let model: HandCaptureModel
    let editing: HandCaptureModel.VillainDraft?
    let onDone: () -> Void

    @State private var position: HeroPosition
    @State private var approxText: String

    init(model: HandCaptureModel, editing: HandCaptureModel.VillainDraft?, onDone: @escaping () -> Void) {
        self.model = model
        self.editing = editing
        self.onDone = onDone
        _position = State(initialValue: editing?.position
            ?? HeroPosition.allCases.first { $0 != model.heroPosition } ?? .utg)
        _approxText = State(initialValue: (editing?.approxStack).map { $0 > 0 ? String($0) : "" } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Position").font(PokerTypography.chipLabel).foregroundColor(.textSecondary)
            PositionGrid(selected: position, disabled: { $0 == model.heroPosition }) { candidate in
                position = candidate
            }

            Text("Relative Stack").font(PokerTypography.chipLabel).foregroundColor(.textSecondary)
            HStack(spacing: 8) {
                ForEach(RelativeStack.allCases, id: \.self) { option in
                    Button(option.rawValue) { commit(relative: option) }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                }
            }

            TextField("≈ stack (optional, e.g. 300k)", text: $approxText)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numbersAndPunctuation)

            Button("Cancel", action: onDone)
                .font(.caption)
                .foregroundColor(.textSecondary)
        }
        .padding(.top, 4)
    }

    /// Tapping a relative-stack option is the commit: it carries enough
    /// information (position + relative size) to add the villain outright.
    /// Editing an existing villain replaces it (remove + re-add) — safe
    /// before the villain has acted, and the engine already drops any of
    /// their recorded actions on removal.
    private func commit(relative: RelativeStack) {
        let approxStack = ChipInput.parse(approxText) ?? 0
        if let editing { model.removeVillain(id: editing.id) }
        model.addVillain(position: position, relative: relative, approxStack: approxStack)
        HapticFeedback.impact(.light)
        onDone()
    }
}

// MARK: - Action ledger

private struct LedgerList: View {
    let model: HandCaptureModel
    @Binding var truncateIndex: Int?

    var body: some View {
        if !model.ledger.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Actions").font(PokerTypography.sectionHeader).foregroundColor(.goldAccent)
                ForEach(Array(model.ledger.enumerated()), id: \.element.id) { index, entry in
                    HStack {
                        Text(rowText(entry))
                            .font(PokerTypography.chatCaption)
                            .foregroundColor(.textPrimary)
                        Spacer()
                        if index == model.ledger.count - 1 {
                            Button { model.undoLast() } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .foregroundColor(.textSecondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if index < model.ledger.count - 1 { truncateIndex = index }
                    }
                }
            }
            .pokerCard()
        }
    }

    private func rowText(_ entry: HandCaptureModel.LedgerEntry) -> String {
        let actor = entry.participant == .hero ? "Hero" : model.label(for: entry.participant)
        let prefix = "\(entry.street.label.uppercased()) — \(actor)"
        switch entry.action {
        case .fold: return "\(prefix) folds"
        case .check: return "\(prefix) checks"
        case .call: return "\(prefix) calls \(entry.toAmount.formatted())"
        case .bet: return "\(prefix) bets \(entry.toAmount.formatted())"
        case .raise: return "\(prefix) raises to \(entry.toAmount.formatted())"
        case .allIn: return "\(prefix) all-in \(entry.toAmount.formatted())"
        }
    }
}

// MARK: - Action entry row

private struct ActionRow: View {
    let model: HandCaptureModel
    @Binding var pendingActionType: HandActionType?

    var body: some View {
        if let actor = model.participantToAct {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(model.label(for: actor)) to act")
                    .font(PokerTypography.sectionHeader)
                    .foregroundColor(.goldAccent)
                HStack(spacing: 8) {
                    ForEach(model.legalActions.filter { $0 != .allIn }, id: \.self) { action in
                        Button {
                            handle(action)
                        } label: {
                            Text(buttonLabel(action))
                                .font(PokerTypography.statValue)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(Color.cardSurface)
                                .foregroundColor(.textPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }
    }

    private func buttonLabel(_ action: HandActionType) -> String {
        switch action {
        case .call: return "Call \(model.currentBet.formatted())"
        case .bet, .raise: return "Bet/Raise"
        default: return action.rawValue
        }
    }

    private func handle(_ action: HandActionType) {
        switch action {
        case .fold, .check:
            model.add(action: action, toAmount: 0)
            HapticFeedback.impact(.light)
        case .call:
            model.add(action: .call, toAmount: 0)
            HapticFeedback.impact(.light)
        case .bet, .raise:
            pendingActionType = action
        case .allIn:
            break
        }
    }
}

// MARK: - Sizing row

private struct SizingRow: View {
    let model: HandCaptureModel
    let actionType: HandActionType
    let onCommit: (HandActionType, Int) -> Void
    let onCancel: () -> Void

    @State private var showNumberPad = false
    @State private var numberPadText = ""

    private let fractionChips: [(String, Double)] = [
        ("⅓", 1.0 / 3), ("½", 0.5), ("⅔", 2.0 / 3), ("Pot", 1.0), ("1.5x", 1.5),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Size").font(PokerTypography.sectionHeader).foregroundColor(.goldAccent)
                Spacer()
                Button("Cancel", action: onCancel)
                    .font(.caption)
                    .foregroundColor(.textSecondary)
            }
            HStack(spacing: 6) {
                ForEach(fractionChips, id: \.0) { label, fraction in
                    Button(label) { commitFraction(fraction) }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                }
                Button("Jam") { commitJam() }
                    .buttonStyle(.bordered)
                    .tint(.chipRed)
                Button("#") {
                    numberPadText = ""
                    showNumberPad = true
                }
                .buttonStyle(.bordered)
                .tint(.goldAccent)
            }
        }
        .pokerCard()
        .alert("Amount", isPresented: $showNumberPad) {
            TextField("e.g. 75k or 3 (BB)", text: $numberPadText)
                .keyboardType(.numbersAndPunctuation)
            Button("OK") {
                if let amount = ChipInput.parse(numberPadText, bigBlindMultiplier: model.bigBlind) {
                    onCommit(actionType, normalizedTotal(amount))
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Rounds a raw pot-fraction amount to a clean chip size: nearest 500
    /// below a 10K big blind, nearest 1000 at or above it (spec 5.1 #7).
    private func roundedChip(_ raw: Double) -> Int {
        guard raw > 0 else { return 0 }
        let unit = model.bigBlind >= 10_000 ? 1000 : 500
        return max(unit, Int((raw / Double(unit)).rounded()) * unit)
    }

    /// A pot-fraction or typed size is the *additional* amount being put in;
    /// against an existing bet that becomes a raise-to total, otherwise it is
    /// the opening bet itself.
    private func normalizedTotal(_ sizeAmount: Int) -> Int {
        model.currentBet > 0 ? model.currentBet + sizeAmount : sizeAmount
    }

    private func commitFraction(_ fraction: Double) {
        let sizeAmount = roundedChip(Double(model.pot) * fraction)
        onCommit(actionType, normalizedTotal(sizeAmount))
    }

    private func commitJam() {
        guard let actor = model.participantToAct else { return }
        if let amount = jamAmount(for: actor) {
            onCommit(.allIn, amount)
        } else {
            numberPadText = ""
            showNumberPad = true
        }
    }

    private func jamAmount(for participant: HandCaptureModel.Participant) -> Int? {
        switch participant {
        case .hero:
            return model.heroStackBefore
        case .villain(let id):
            let approx = model.villains.first { $0.id == id }?.approxStack ?? 0
            return approx > 0 ? approx : nil
        }
    }
}

// MARK: - Board entry

private struct BoardEntry: View {
    let model: HandCaptureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(model.currentStreet.label) card\(model.boardCardsNeeded > 1 ? "s (\(model.boardCardsNeeded))" : "")")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
            CardPickerGrid(dealt: model.dealtCards) { card in
                if model.addBoardCard(card) { HapticFeedback.impact(.light) }
            }
        }
        .pokerCard()
    }
}

// MARK: - Result block

private struct ResultBlock: View {
    let model: HandCaptureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Result").font(PokerTypography.sectionHeader).foregroundColor(.goldAccent)

            if model.needsShowdown {
                ForEach(model.villains.filter { !model.foldedParticipants.contains(.villain($0.id)) }) { villain in
                    VillainShowdownRow(model: model, villain: villain)
                }
            }

            Text(resultLine)
                .font(PokerTypography.statValue)
                .foregroundColor(model.heroNet >= 0 ? .mZoneGreen : .chipRed)

            Menu {
                Button("Trust Computed Result") { model.winnerOverride = nil }
                ForEach(overrideCandidates, id: \.self) { participant in
                    Button("Award to \(model.label(for: participant))") { model.winnerOverride = [participant] }
                }
                if overrideCandidates.count > 1 {
                    Button("Chop (\(overrideCandidates.count)-way)") {
                        model.winnerOverride = Set(overrideCandidates)
                    }
                }
            } label: {
                Label("Override Winner", systemImage: "flag")
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(.textSecondary)
            }
        }
        .pokerCard()
    }

    private var overrideCandidates: [HandCaptureModel.Participant] {
        var participants: [HandCaptureModel.Participant] = [.hero]
        participants.append(contentsOf: model.villains.map { .villain($0.id) })
        return participants.filter { !model.foldedParticipants.contains($0) }
    }

    private var resultLine: String {
        if model.winnerOverride == nil, model.needsShowdown, model.computedWinners.isEmpty {
            return "Enter shown holdings (or override) to resolve the winner."
        }
        let net = model.heroNet
        let verb = net >= 0 ? "wins" : "loses"
        return "Hero \(verb) \(abs(net).formatted())"
    }
}

/// A villain's showdown resolution is either already known (shown holding or
/// mucked) or not — the card picker appears automatically while unresolved,
/// with no separate "reveal" tap; resolved rows collapse to a read-only
/// summary with a lightweight "Edit" affordance to reopen it.
private struct VillainShowdownRow: View {
    let model: HandCaptureModel
    let villain: HandCaptureModel.VillainDraft

    @State private var forceEditing = false

    private var isResolved: Bool { villain.shownHolding.count == 2 || villain.mucked }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.label(for: .villain(villain.id)))
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(.textPrimary)
                Spacer()
                if villain.shownHolding.count == 2 {
                    Text(villain.shownHolding.map(\.display).joined(separator: " "))
                        .font(PokerTypography.statValue)
                        .foregroundColor(.textPrimary)
                }
                if villain.mucked {
                    Text("Mucked").font(PokerTypography.chipLabel).foregroundColor(.textSecondary)
                }
                if isResolved {
                    Button("Edit") { forceEditing = true }
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                } else {
                    Button("Mucked") { model.setMucked(villain.id) }
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                }
            }
            if !isResolved || forceEditing {
                CardPickerGrid(dealt: model.dealtCards) { card in
                    var cards = villain.shownHolding
                    guard cards.count < 2 else { return }
                    cards.append(card)
                    model.setShownHolding(cards, for: villain.id)
                    if cards.count == 2 { forceEditing = false }
                }
            }
        }
    }
}
