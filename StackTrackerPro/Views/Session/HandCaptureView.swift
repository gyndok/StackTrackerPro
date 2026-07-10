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
    /// When true and the ledger is still empty on appear, opens the dictation
    /// sheet immediately — the voice-first entry points (Task 5) route here.
    let autoStartDictation: Bool
    /// Non-nil when re-opening a saved hand to edit it (device finding 16).
    /// Drives reconstruction (the model is seeded via `init(editing:)`) and the
    /// save path: the original is deleted, its timestamp / source-stub link are
    /// carried onto the new hand, and no tracker stack update is pushed.
    let editingHand: Hand?

    @State private var model: HandCaptureModel
    @AppStorage(SettingsKeys.defaultSeatsPerTable) private var seatsDefault = 9

    @State private var showCloseConfirm = false
    @State private var truncateIndex: Int?
    @State private var showPotPad = false
    @State private var potPadText = ""
    @State private var showStackPad = false
    @State private var stackPadText = ""
    @State private var villainEditorTarget: VillainEditorTarget?
    /// Villain currently showing the "Shown cards" editor, opened from the
    /// villain row's always-enabled "eye" button (see `villainSection`).
    /// Deliberately separate from `villainEditorTarget`: that editor's chip
    /// disables once the villain has acted (editing is remove-and-re-add,
    /// which would drop their ledger entries), but shown cards are not a
    /// replay input — they must stay settable regardless of `hasActed`
    /// (all-in hands routinely reveal cards before the runout finishes).
    @State private var shownCardsTarget: UUID?
    @State private var pendingRemovalID: UUID?
    @State private var pendingActionType: HandActionType?
    @State private var showDictation = false
    /// The just-recorded transcript, held while confirming a replace of an
    /// existing one (`onResult` never writes straight to `model.transcript`
    /// when one is already present).
    @State private var pendingTranscript: String?
    @State private var showReplaceTranscriptConfirm = false
    @State private var showLevelPicker = false
    @State private var showSavedDialog = false
    @State private var showSavedShare = false
    @State private var savedHand: Hand?

    init(tournament: Tournament?, cashSession: CashSession?, stub: HandStub?,
         autoStartDictation: Bool = false, editingHand: Hand? = nil,
         onSaved: @escaping (Hand) -> Void) {
        self.tournament = tournament
        self.cashSession = cashSession
        self.stub = stub
        self.autoStartDictation = autoStartDictation
        self.editingHand = editingHand
        self.onSaved = onSaved

        let gameType = tournament?.gameType ?? cashSession?.gameType
        let cardCount = gameType == .plo ? 4 : 2

        if let editingHand {
            // Rebuild the whole capture from the saved hand (see
            // HandCaptureModel.init(editing:)). A manual pot correction is
            // re-prefilled only when the saved potSize diverges from the
            // recomputed pot — a computed pot is not re-frozen as an override.
            let m = HandCaptureModel(editing: editingHand, heroCardCount: cardCount)
            if editingHand.potSize > 0, editingHand.potSize != m.pot {
                m.potOverride = editingHand.potSize
            }
            // Restore a persisted manual winner ruling by label matching (see
            // restoreWinnerOverride's contract) — placed after init so no
            // reconstruction step clears it. Without this, a PLO showdown
            // (saveable only via override) would reopen with Save disabled,
            // and an NLHE dealer correction would silently revert on save.
            m.restoreWinnerOverride(fromLabels: editingHand.winnerOverride)
            _model = State(initialValue: m)
        } else if let stub {
            // Capture the tracker stack now so the model can tell a just-happened
            // enrichment (stack unchanged) from a stale one (stack moved on) —
            // see HandCaptureModel.shouldPushStackUpdate.
            let trackerStack = tournament?.latestStack?.chipCount ?? cashSession?.latestStack?.chipCount
            _model = State(initialValue: HandCaptureModel(stub: stub, heroCardCount: cardCount,
                                                          trackerStackAtOpen: trackerStack))
        } else if let tournament {
            let blinds = tournament.currentBlinds
            _model = State(initialValue: HandCaptureModel(
                // Display-facing level number (matches the stub convention and
                // the manual level picker), not the internal blind-level index.
                levelNumber: tournament.currentDisplayLevel ?? tournament.currentBlindLevelNumber,
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
                        NarrationBar(model: model, showPotPad: $showPotPad, potPadText: $potPadText,
                                     canPickLevel: !levelOptions.isEmpty,
                                     onPickLevel: { showLevelPicker = true })
                        if !model.transcript.isEmpty {
                            TranscriptCard(transcript: model.transcript)
                        }
                        HeroStrip(model: model, stubHint: stubHint,
                                 showStackPad: $showStackPad, stackPadText: $stackPadText)
                        villainSection
                        LedgerList(model: model, truncateIndex: $truncateIndex)

                        if model.participantToAct != nil {
                            // With zero committed villains the hero is the only
                            // participant, so the engine (correctly) ends the
                            // hand after a single action — "Hero wins" out of
                            // nowhere. Gate action entry behind having an
                            // opponent instead of rendering that footgun. Only
                            // for pristine hands (empty ledger); a hand already
                            // in flight is never blocked. Committed villains
                            // only: an open-but-uncommitted editor still shows
                            // the hint.
                            if model.villains.isEmpty && model.ledger.isEmpty {
                                Text("Add at least one villain first — the hand needs an opponent")
                                    .font(PokerTypography.chipLabel)
                                    .foregroundColor(.textSecondary)
                            } else {
                                ActionRow(model: model, pendingActionType: $pendingActionType)
                            }
                        }
                        if let type = pendingActionType {
                            SizingRow(model: model, actionType: type,
                                     onCommit: commitSizedAction, onCancel: { pendingActionType = nil })
                        }
                        // Mounted whenever any board exists, not just while
                        // cards are owed: addBoardCard rebuilds synchronously,
                        // so a street-closing card drops boardCardsNeeded to 0
                        // in the same call — gating on `needed > 0` alone would
                        // unmount the section (and the last card's inline
                        // delete) the instant the flop's 3rd / turn / river
                        // card is picked.
                        if !model.board.isEmpty || model.boardCardsNeeded > 0 {
                            BoardEntry(model: model)
                        }
                        if model.isHandOver {
                            ResultBlock(model: model)
                            tagRow
                            saveButton
                        } else if !model.transcript.isEmpty {
                            // Transcript-only capture: the ledger never
                            // started (no showdown/result to show), but a
                            // dictated transcript alone is savable —
                            // `canSave` is true off `!transcript.isEmpty`
                            // even though `isResolvable` requires
                            // `isHandOver`. Surface tags + Save without the
                            // (meaningless, pre-hand) Result block.
                            tagRow
                            saveButton
                        }
                    }
                    .padding(16)
                }
                // Inline number fields (sizing "#", villain approx stack) open
                // the keyboard mid-scroll; dragging the capture surface should
                // put it away (F18).
                .scrollDismissesKeyboard(.interactively)
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
                        showDictation = true
                    } label: {
                        Image(systemName: "mic.fill")
                    }
                    .foregroundColor(.goldAccent)
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
        .onAppear {
            if autoStartDictation && model.ledger.isEmpty {
                showDictation = true
            }
        }
        .sheet(isPresented: $showDictation) {
            DictationSheet { transcript in
                if model.transcript.isEmpty {
                    model.transcript = transcript
                } else {
                    // Dictating again REPLACES the transcript — confirm first
                    // rather than silently discarding what's already there.
                    pendingTranscript = transcript
                    showReplaceTranscriptConfirm = true
                }
            }
        }
        .sheet(isPresented: $showLevelPicker) {
            LevelPickerSheet(options: levelOptions, currentLevel: model.levelNumber) { option in
                model.setLevel(number: option.displayNumber, smallBlind: option.smallBlind,
                               bigBlind: option.bigBlind, ante: option.ante)
                showLevelPicker = false
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
        .confirmationDialog(
            "Replace existing transcript?",
            isPresented: $showReplaceTranscriptConfirm,
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) {
                if let pendingTranscript { model.transcript = pendingTranscript }
                pendingTranscript = nil
            }
            Button("Cancel", role: .cancel) { pendingTranscript = nil }
        }
        .confirmationDialog(
            removalDialogTitle,
            isPresented: Binding(get: { pendingRemovalID != nil }, set: { if !$0 { pendingRemovalID = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Villain", role: .destructive) {
                if let id = pendingRemovalID { removeVillain(id) }
                pendingRemovalID = nil
            }
            Button("Cancel", role: .cancel) { pendingRemovalID = nil }
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
        .confirmationDialog("Hand saved", isPresented: $showSavedDialog, titleVisibility: .visible) {
            Button("Share…") { showSavedShare = true }
            Button("Done", role: .cancel) { dismiss() }
        } message: { Text("Share it or head back to the table.") }
        .sheet(isPresented: $showSavedShare, onDismiss: { dismiss() }) {
            if let savedHand { HandSharePreview(hand: savedHand) }
        }
    }

    // MARK: - Villain section

    private var villainSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Villains").font(PokerTypography.sectionHeader).foregroundColor(.goldAccent)
            ForEach(model.villains) { villain in
                let hasActed = model.hasActed(.villain(villain.id))
                HStack(spacing: 8) {
                    // Editing is remove-and-re-add under a new id, which would
                    // silently strip the villain's recorded ledger actions —
                    // so the edit affordance locks once they have acted.
                    Button {
                        villainEditorTarget = villainEditorTarget == .editing(villain.id)
                            ? nil : .editing(villain.id)
                    } label: {
                        Text(villainChipText(villain))
                    }
                    .quickChip()
                    .disabled(hasActed)
                    // Always enabled — unlike the chip above, setting a shown
                    // holding is never a replay input, so it must stay
                    // reachable even after the villain has acted (all-ins
                    // routinely show cards before the runout completes).
                    Button {
                        shownCardsTarget = shownCardsTarget == villain.id ? nil : villain.id
                    } label: {
                        Image(systemName: shownCardsTarget == villain.id ? "eye.fill" : "eye")
                    }
                    .foregroundColor(.goldAccent)
                    .accessibilityLabel("Shown cards")
                    Spacer()
                    Button {
                        // Confirm (never silently) when removal drops recorded
                        // actions OR collapses the hand: removing the only
                        // committed villain mid-hand leaves the hero as the
                        // sole participant, so the replay ends the hand on
                        // the first hero action — "Hero wins" out of nowhere
                        // (device finding 10). That case needs a warning even
                        // when the villain themselves never acted.
                        if hasActed || isLastVillainMidHand {
                            pendingRemovalID = villain.id
                        } else {
                            removeVillain(villain.id)
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .foregroundColor(.chipRed)
                }
                if shownCardsTarget == villain.id {
                    VillainShownCardsEditor(model: model, villainID: villain.id) {
                        shownCardsTarget = nil
                    }
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
                // Per-target identity: without .id, SwiftUI reuses the editor's
                // @State when switching directly between targets (edit A → edit
                // B, or edit → add), leaking A's position/stack into B.
                VillainInlineEditor(model: model, editing: editing(for: target)) {
                    villainEditorTarget = nil
                }
                .id(target)
            }
        }
        .pokerCard()
    }

    private func editing(for target: VillainEditorTarget) -> HandCaptureModel.VillainDraft? {
        guard case .editing(let id) = target else { return nil }
        return model.villains.first { $0.id == id }
    }

    /// True when the hand is in flight and only one committed villain remains —
    /// removing them collapses the replay to hero-only and ends the hand.
    private var isLastVillainMidHand: Bool {
        model.villains.count == 1 && !model.ledger.isEmpty
    }

    private var removalDialogTitle: String {
        if isLastVillainMidHand {
            return "Removing the only opponent ends the hand — its actions will be removed too."
        }
        return "Remove this villain? Their recorded actions will be removed and the hand replayed without them."
    }

    /// Single removal path: closes any editor still pointed at the villain
    /// before dropping them, so a stale open editor can't later resurrect the
    /// removed villain with old values (device finding 11).
    private func removeVillain(_ id: UUID) {
        if villainEditorTarget == .editing(id) { villainEditorTarget = nil }
        if shownCardsTarget == id { shownCardsTarget = nil }
        model.removeVillain(id: id)
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

    // MARK: - Manual level selection (F15)

    /// The tournament's non-break structure levels, labeled with DISPLAY level
    /// numbers, offered in the level picker. Empty for cash sessions (no
    /// structure) — the narration header is then not tappable.
    private var levelOptions: [LevelPickerOption] {
        guard let tournament else { return [] }
        let displayNumbers = tournament.displayLevelNumbers
        return tournament.sortedBlindLevels
            .filter { !$0.isBreak }
            .map { level in
                LevelPickerOption(
                    displayNumber: displayNumbers[level.levelNumber] ?? level.levelNumber,
                    smallBlind: level.smallBlind, bigBlind: level.bigBlind, ante: level.ante)
            }
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

    /// Save gating lives on the engine (`HandCaptureModel.canSave`, unit
    /// tested): either the ledger resolves (hand over, and any showdown
    /// either overridden or fully resolved with evaluable winners) OR a
    /// verbatim transcript exists to persist on its own (Task 2).
    private var saveButton: some View {
        Button {
            save()
        } label: {
            Text("Save Hand")
        }
        .buttonStyle(PokerButtonStyle(isEnabled: model.canSave))
        .disabled(!model.canSave)
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
        // On the edit path, re-link the ORIGINAL hand's source stub (so the
        // stub keeps pointing at the current enriched hand) and carry its
        // timestamp onto the replacement below.
        let effectiveStub = editingHand?.sourceStub ?? stub
        let hand = model.save(into: modelContext, tournament: tournament, cashSession: cashSession,
                              sourceStub: effectiveStub, tableSize: seatsDefault)

        if let editingHand {
            // Editing is a replace-in-place: preserve the original position in
            // the timeline, then delete the original (its actions/villains
            // cascade). Editing history must NOT touch the tracker, so no stack
            // update is pushed regardless of shouldPushStackUpdate.
            hand.timestamp = editingHand.timestamp
            modelContext.delete(editingHand)
        } else if tournament != nil, model.heroStackAfter > 0, model.shouldPushStackUpdate {
            // Only push the stack update for a current, non-edit hand — a stale
            // enrichment would regress latestStack (see shouldPushStackUpdate).
            tournamentManager.updateStack(chipCount: model.heroStackAfter)
        }
        HapticFeedback.success()
        onSaved(hand)
        savedHand = hand
        showSavedDialog = true
    }
}

// MARK: - Chip input parsing

/// Parses free-form chip amounts: "390k"/"42.5k" for thousands, "1.2m" for
/// millions, otherwise a literal bare integer. Used by the pot/stack pads and
/// the villain approx-stack field. (The bet-sizing pad has its own parser,
/// `SizingInput`, which adds the explicit "bb" suffix — the implicit
/// short-number-means-BB-multiple heuristic that used to live here made
/// typed amounts unpredictable and is gone.)
enum ChipInput {
    static func parse(_ raw: String) -> Int? {
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
        return value
    }
}

/// Pure parser for the bet-sizing "#" pad. Semantics are LITERAL — what you
/// type is the raise-to/bet total in chips (device finding 13; the old pad
/// both multiplied short numbers by the big blind and added `currentBet` on
/// top, so "2300" committed as 2300 + BB):
/// - bare number ("2300") -> exactly 2300 chips;
/// - "bb" suffix ("4bb", "2.5bb", "4 bb", case-insensitive) -> value x bigBlind,
///   rounded to the nearest chip;
/// - "k"/"m" shorthand ("42.5k", "1.2m") -> thousands/millions;
/// - zero, empty, or unparseable -> nil.
enum SizingInput {
    static func parse(_ raw: String, bigBlind: Int) -> Int? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return nil }
        if cleaned.hasSuffix("bb") {
            let numText = cleaned.dropLast(2).trimmingCharacters(in: .whitespaces)
            guard bigBlind > 0, let num = Double(numText), num > 0 else { return nil }
            return Int((num * Double(bigBlind)).rounded())
        }
        if cleaned.hasSuffix("k") {
            guard let num = Double(cleaned.dropLast()), num > 0 else { return nil }
            return Int((num * 1000).rounded())
        }
        if cleaned.hasSuffix("m") {
            guard let num = Double(cleaned.dropLast()), num > 0 else { return nil }
            return Int((num * 1_000_000).rounded())
        }
        guard let value = Int(cleaned), value > 0 else { return nil }
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
    /// True when a tournament structure is present: the narration header (which
    /// leads with the level/blinds) becomes a tappable control that opens the
    /// manual level picker (device finding 15). Hidden for cash sessions.
    var canPickLevel = false
    var onPickLevel: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if canPickLevel {
                Button(action: onPickLevel) {
                    HStack(alignment: .top, spacing: 4) {
                        narrationText
                        Image(systemName: "chevron.down.circle")
                            .font(.caption2)
                            .foregroundColor(.goldAccent)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change level for this hand")
            } else {
                narrationText
            }
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

    private var narrationText: some View {
        Text(model.narration)
            .font(.system(.footnote, design: .monospaced))
            .foregroundColor(.textPrimary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Transcript card

/// Collapsible read-only display of the verbatim dictation transcript
/// (Task 2 — the visual reference for tap-entry). Rendered directly under
/// the narration bar whenever `model.transcript` is non-empty; monospaced,
/// scrollable past a fixed max height, default expanded, theme-consistent
/// with the other capture-screen cards (`.pokerCard()`).
private struct TranscriptCard: View {
    let transcript: String
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Text("Transcript")
                        .font(PokerTypography.sectionHeader)
                        .foregroundColor(.goldAccent)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.goldAccent)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse transcript" : "Expand transcript")

            if isExpanded {
                ScrollView {
                    Text(transcript)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
        }
        .pokerCard()
    }
}

// MARK: - Level picker (F15)

/// One selectable structure level in the manual level picker, carrying the
/// DISPLAY level number (not the internal blind-level index) and its blinds.
struct LevelPickerOption: Identifiable {
    let displayNumber: Int
    let smallBlind: Int
    let bigBlind: Int
    let ante: Int

    var id: Int { displayNumber }

    /// "L5 — 300/600 (600)" — display number, blinds, and ante when present.
    var label: String {
        var text = "L\(displayNumber) — \(smallBlind.formatted())/\(bigBlind.formatted())"
        if ante > 0 { text += " (\(ante.formatted()))" }
        return text
    }
}

/// Scrolling list of the tournament's non-break levels for re-tagging the hand
/// with the level it was actually played at. The current level is checkmarked.
private struct LevelPickerSheet: View {
    let options: [LevelPickerOption]
    let currentLevel: Int
    let onSelect: (LevelPickerOption) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.backgroundPrimary.ignoresSafeArea()
                List(options) { option in
                    Button {
                        onSelect(option)
                    } label: {
                        HStack {
                            Text(option.label)
                                .foregroundColor(.textPrimary)
                            Spacer()
                            if option.displayNumber == currentLevel {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.goldAccent)
                            }
                        }
                    }
                    .listRowBackground(Color.cardSurface)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Level Played")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Card chip

/// A single dealt/held card rendered as a chip — the shared look used for the
/// hero's hole cards, the board-so-far row, and a villain's shown holding. An
/// optional trailing "x" removes the card via `onRemove` when the caller
/// allows it (the board row only wires this up for the last card, and only
/// when `HandCaptureModel.lastInputWasBoardCard` — see `BoardEntry`).
private struct CardChip: View {
    let card: PlayingCard
    var onRemove: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(card.display)
                .font(PokerTypography.statValue)
                .foregroundColor(card.isRed ? .red : .textPrimary)
                .frame(width: 48, height: 60)
                .background(Color.backgroundPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.chipRed)
                        .background(Circle().fill(Color.backgroundPrimary))
                }
                .buttonStyle(.plain)
                .offset(x: 8, y: -8)
            }
        }
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
                    CardChip(card: card)
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

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Stack at start of hand").foregroundColor(.textSecondary)
                    Spacer()
                    // Styled as an obvious input (field chrome + pencil):
                    // the bare-label version read as static text and users
                    // never realized it was editable (device finding 9).
                    Button {
                        stackPadText = String(model.heroStackBefore)
                        showStackPad = true
                    } label: {
                        HStack(spacing: 6) {
                            Text(model.heroStackBefore.formatted())
                                .font(PokerTypography.statValue)
                                .foregroundColor(.textPrimary)
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundColor(.goldAccent)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.backgroundPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.goldAccent.opacity(0.4), lineWidth: 1)
                        )
                    }
                    .accessibilityLabel("Stack at start of hand, \(model.heroStackBefore.formatted()), edit")
                }
                // Enrich-at-break staleness: when the tracker's stack at open
                // differs from the (stub-snapshotted) starting stack, offer
                // the current tracker value as a one-tap correction.
                if let tracker = model.trackerStackAtOpen, tracker != model.heroStackBefore {
                    HStack(spacing: 8) {
                        Text("Tracker now: \(tracker.formatted())")
                            .font(PokerTypography.chipLabel)
                            .foregroundColor(.textSecondary)
                        Button("Use current") { model.heroStackBefore = tracker }
                            .font(.caption)
                            .foregroundColor(.goldAccent)
                    }
                }
            }
        }
        .pokerCard()
    }
}

// MARK: - Villain editor

/// Which inline villain editor is expanded, if any: a fresh add, or an
/// existing villain re-opened for editing.
private enum VillainEditorTarget: Hashable {
    case adding
    case editing(UUID)
}

/// Inline villain add/edit form. Every control SELECTS (position, relative
/// stack, optional approx stack) and nothing commits until the explicit
/// primary button ("Add Villain" / "Done") — the earlier tap-a-stack-chip-to-
/// commit flow stranded anyone who typed the stack amount first and left no
/// discoverable way to finish (device finding 6).
private struct VillainInlineEditor: View {
    let model: HandCaptureModel
    let editing: HandCaptureModel.VillainDraft?
    let onDone: () -> Void

    @State private var position: HeroPosition
    @State private var relative: RelativeStack
    @State private var approxText: String
    @FocusState private var approxFocused: Bool

    init(model: HandCaptureModel, editing: HandCaptureModel.VillainDraft?, onDone: @escaping () -> Void) {
        self.model = model
        self.editing = editing
        self.onDone = onDone
        _position = State(initialValue: editing?.position
            ?? HeroPosition.allCases.first { seat in
                seat != model.heroPosition && !model.villains.contains { $0.position == seat }
            } ?? .utg)
        // "Covers me" preselected: the most common read, and it means the
        // primary button is always one tap away even if the user skips the
        // relative-stack row entirely.
        _relative = State(initialValue: editing?.relative ?? .coversHero)
        _approxText = State(initialValue: (editing?.approxStack).map { $0 > 0 ? String($0) : "" } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Position").font(PokerTypography.chipLabel).foregroundColor(.textSecondary)
            // A seat can hold one player: the hero's seat and every seat taken
            // by another villain are disabled (the villain being edited keeps
            // its own seat selectable).
            PositionGrid(selected: position, disabled: { seat in
                seat == model.heroPosition
                    || model.villains.contains { $0.id != editing?.id && $0.position == seat }
            }) { candidate in
                position = candidate
            }

            Text("Relative Stack").font(PokerTypography.chipLabel).foregroundColor(.textSecondary)
            HStack(spacing: 8) {
                ForEach(RelativeStack.allCases, id: \.self) { option in
                    Button(option.rawValue) { relative = option }
                        .buttonStyle(.bordered)
                        .tint(relative == option ? .goldAccent : .secondary)
                }
            }

            TextField("≈ stack (optional, e.g. 300k)", text: $approxText)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numbersAndPunctuation)
                .focused($approxFocused)
                // Keyboard Done: no return key on this layout either (F18).
                // Content is gated on THIS field's focus: this editor and
                // SizingRow's "#" pad can be mounted simultaneously, and
                // SwiftUI concatenates every mounted keyboard toolbar into
                // one accessory bar — ungated, two Done buttons would appear.
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        if approxFocused {
                            Spacer()
                            Button("Done") { approxFocused = false }
                        }
                    }
                }

            HStack {
                Button(editing == nil ? "Add Villain" : "Done", action: commit)
                    .buttonStyle(.borderedProminent)
                    .tint(.goldAccent)
                Button("Cancel", action: onDone)
                    .font(.caption)
                    .foregroundColor(.textSecondary)
            }
        }
        .padding(.top, 4)
    }

    /// Explicit commit from the primary button. Editing an existing villain
    /// replaces it (remove + re-add) — safe before the villain has acted, and
    /// the engine already drops any of their recorded actions on removal.
    private func commit() {
        if let editing {
            // Stale-editor guard: the villain may have been removed while
            // this editor stayed open (minus button, or a dictation-applied
            // draft replacing the roster). Committing then would resurrect
            // them with stale values — bail instead, same pattern as the
            // hasActed race guard below.
            guard model.villains.contains(where: { $0.id == editing.id }) else { onDone(); return }
            // Race guard: the chip locks once a villain has acted, but the
            // editor may already be open when their first action is recorded
            // below — committing then would strip that action. Bail instead.
            guard !model.hasActed(.villain(editing.id)) else { onDone(); return }
            model.removeVillain(id: editing.id)
        }
        let approxStack = ChipInput.parse(approxText) ?? 0
        model.addVillain(position: position, relative: relative, approxStack: approxStack)
        HapticFeedback.impact(.light)
        onDone()
    }
}

/// Lets a villain's shown holding be entered (or cleared) at any point in the
/// hand — including mid-runout all-ins, where cards get shown before the
/// board finishes — regardless of whether the villain has already acted.
/// Opened from the always-enabled "eye" button next to the villain chip
/// (see `HandCaptureView.villainSection`), not the position/stack editor,
/// which locks after `hasActed` since it replaces the villain's identity.
private struct VillainShownCardsEditor: View {
    let model: HandCaptureModel
    let villainID: UUID
    let onDone: () -> Void

    private var villain: HandCaptureModel.VillainDraft? {
        model.villains.first { $0.id == villainID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Shown Cards").font(PokerTypography.chipLabel).foregroundColor(.textSecondary)
                Spacer()
                Button("Done", action: onDone)
                    .font(.caption)
                    .foregroundColor(.textSecondary)
            }
            if let villain, !villain.shownHolding.isEmpty {
                HStack(spacing: 8) {
                    ForEach(villain.shownHolding, id: \.self) { card in
                        CardChip(card: card) {
                            model.setShownHolding(villain.shownHolding.filter { $0 != card }, for: villainID)
                        }
                    }
                    Spacer()
                    // With a single card the chip's own remove badge already
                    // covers clearing; the bulk Clear only earns its spot
                    // once there are 2+ cards to wipe in one tap.
                    if villain.shownHolding.count > 1 {
                        Button("Clear") { model.setShownHolding([], for: villainID) }
                            .font(.caption)
                            .foregroundColor(.chipRed)
                    }
                }
            }
            if let villain, villain.shownHolding.count < model.heroCardCount {
                CardPickerGrid(dealt: model.dealtCards) { card in
                    guard let current = self.villain else { return }
                    model.setShownHolding(current.shownHolding + [card], for: villainID)
                }
            }
        }
        .padding(.top, 4)
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
    @FocusState private var numberPadFocused: Bool

    private let fractionChips: [(String, Double)] = [
        ("⅓", 1.0 / 3), ("½", 0.5), ("⅔", 2.0 / 3), ("Pot", 1.0), ("1.5x", 1.5),
    ]

    /// Preset chips with their fully-resolved raise-to totals. Preflop thinks
    /// in big blinds (2bb / 2.5bb / 3bb / Pot — device finding 13A), computed
    /// through `SizingInput.parse` so the chip labels ARE the parser inputs
    /// (one tested source of truth); postflop keeps the pot-fraction presets.
    private var presetChips: [(label: String, toAmount: Int)] {
        if model.currentStreet == .preflop {
            var chips: [(String, Int)] = ["2bb", "2.5bb", "3bb"].map {
                ($0, SizingInput.parse($0, bigBlind: model.bigBlind) ?? 0)
            }
            chips.append(("Pot", normalizedTotal(roundedChip(Double(model.pot)))))
            return chips
        }
        return fractionChips.map {
            ($0.0, normalizedTotal(roundedChip(Double(model.pot) * $0.1)))
        }
    }

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
                ForEach(presetChips, id: \.label) { chip in
                    Button(chip.label) { onCommit(actionType, chip.toAmount) }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                        // An aggressive total at or below the amount to match
                        // is nonsense (a "raise to 2.5bb" facing 5bb); gray it
                        // out rather than let the engine book it.
                        .disabled(chip.toAmount <= model.currentBet)
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
            // Inline literal-amount entry (not an alert: the confirm label
            // previews the resolved total live, and alert action buttons
            // don't reliably re-render while typing).
            if showNumberPad {
                HStack(spacing: 8) {
                    TextField("e.g. 2300, 4bb or 42.5k", text: $numberPadText)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                        .focused($numberPadFocused)
                        // Keyboard Done: numbers-and-punctuation has no return
                        // key to lean on, so give the keyboard an explicit
                        // dismiss (F18). Gated on focus for the same co-mount
                        // reason as the villain editor's approx field — both
                        // toolbars concatenate when both views are mounted.
                        .toolbar {
                            ToolbarItemGroup(placement: .keyboard) {
                                if numberPadFocused {
                                    Spacer()
                                    Button("Done") { numberPadFocused = false }
                                }
                            }
                        }
                    Button(confirmLabel) {
                        if let amount = resolvedAmount {
                            onCommit(actionType, amount)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.goldAccent)
                    .disabled(resolvedAmount == nil)
                }
            }
        }
        .pokerCard()
    }

    /// The typed amount, resolved LITERALLY by `SizingInput` — no additions,
    /// no big-blind heuristics (finding 13B).
    private var resolvedAmount: Int? {
        SizingInput.parse(numberPadText, bigBlind: model.bigBlind)
    }

    /// Live preview of exactly what will be committed, e.g. "Raise to 2,300".
    private var confirmLabel: String {
        let verb = actionType == .raise ? "Raise to" : "Bet"
        guard let amount = resolvedAmount else { return verb }
        return "\(verb) \(amount.formatted())"
    }

    /// Rounds a raw pot-fraction amount to a clean chip size: nearest 500
    /// below a 10K big blind, nearest 1000 at or above it (spec 5.1 #7).
    private func roundedChip(_ raw: Double) -> Int {
        guard raw > 0 else { return 0 }
        let unit = model.bigBlind >= 10_000 ? 1000 : 500
        return max(unit, Int((raw / Double(unit)).rounded()) * unit)
    }

    /// A pot-fraction preset is the *additional* amount being put in; against
    /// an existing bet that becomes a raise-to total, otherwise it is the
    /// opening bet itself. (Preset math only — the "#" pad is literal.)
    private func normalizedTotal(_ sizeAmount: Int) -> Int {
        model.currentBet > 0 ? model.currentBet + sizeAmount : sizeAmount
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
            // Street header only while cards are owed; once a street's cards
            // complete this section stays mounted (see the mount condition in
            // HandCaptureView.body) so the board — and the last card's inline
            // delete — remains visible through the following betting round.
            Text(model.boardCardsNeeded > 0
                 ? "\(model.streetBeingDealt.label) card\(model.boardCardsNeeded > 1 ? "s (\(model.boardCardsNeeded))" : "")"
                 : "Board")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
            if !model.board.isEmpty {
                HStack(spacing: 8) {
                    ForEach(model.board, id: \.self) { card in
                        CardChip(card: card, onRemove: isLastPick(card) ? { model.undoLast() } : nil)
                    }
                }
            }
            if model.boardCardsNeeded > 0 {
                CardPickerGrid(dealt: model.dealtCards) { card in
                    if model.addBoardCard(card) { HapticFeedback.impact(.light) }
                }
            }
        }
        .pokerCard()
    }

    /// Only the very last dealt board card is removable, and only while it is
    /// genuinely the last thing entered (see `lastInputWasBoardCard`) — never
    /// an earlier street's card, which would corrupt the replay.
    private func isLastPick(_ card: PlayingCard) -> Bool {
        card == model.board.last && model.lastInputWasBoardCard
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

            // An active override must be loud: it silently flips the booked
            // result away from the computed one, and an invisible stale
            // override reads as an engine bug ("Hero loses" on a won hand —
            // device finding 14). One tap clears it.
            if let override = model.winnerOverride {
                HStack(spacing: 8) {
                    Label("Winner overridden: \(overrideDescription(override))",
                          systemImage: "flag.fill")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.chipRed)
                    Spacer()
                    Button("Clear override") { model.winnerOverride = nil }
                        .font(.caption)
                        .foregroundColor(.goldAccent)
                }
            }

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
                Label(model.winnerOverride == nil ? "Override Winner" : "Change override",
                      systemImage: model.winnerOverride == nil ? "flag" : "flag.fill")
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(.textSecondary)
            }
        }
        .pokerCard()
    }

    /// Human-readable override target(s), matching what `save` persists
    /// (label(for:), sorted, comma-joined).
    private func overrideDescription(_ override: Set<HandCaptureModel.Participant>) -> String {
        override.map { model.label(for: $0) }.sorted().joined(separator: ", ")
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
