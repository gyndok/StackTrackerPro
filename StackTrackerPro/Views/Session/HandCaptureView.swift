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
    /// villain row's always-enabled "eye" button (see `VillainSection`).
    /// Deliberately separate from `villainEditorTarget`: that editor's chip
    /// disables once the villain has acted (editing is remove-and-re-add,
    /// which would drop their ledger entries), but shown cards are not a
    /// replay input — they must stay settable regardless of `hasActed`
    /// (all-in hands routinely reveal cards before the runout finishes).
    @State private var shownCardsTarget: UUID?
    @State private var pendingActionType: HandActionType?
    @State private var heroCardsDeferred = false
    @State private var showDictation = false
    /// The just-recorded transcript, held while confirming a replace of an
    /// existing one (`onResult` never writes straight to `model.transcript`
    /// when one is already present). Non-nil presents the replace-confirm
    /// dialog; the dialog's derived binding clears it on ANY dismissal —
    /// Cancel or tap-outside — so a discarded transcript never lingers
    /// (same pattern as `truncateIndex`).
    @State private var pendingTranscript: String?
    @State private var showLevelPicker = false

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
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            NarrationBar(model: model, showPotPad: $showPotPad, potPadText: $potPadText,
                                         canPickLevel: !levelOptions.isEmpty,
                                         onPickLevel: { showLevelPicker = true })
                            if !model.transcript.isEmpty {
                                TranscriptCard(transcript: model.transcript,
                                              warnIfEmptiedWithoutStructure: !model.isResolvable) {
                                    model.transcript = $0
                                }
                            }
                            HeroSetupSection(model: model, stubHint: stubHint,
                                            heroCardsDeferred: $heroCardsDeferred,
                                            showStackPad: $showStackPad, stackPadText: $stackPadText)
                            VillainSection(model: model, villainEditorTarget: $villainEditorTarget,
                                          shownCardsTarget: $shownCardsTarget)
                            LedgerList(model: model, truncateIndex: $truncateIndex)
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
                    .scrollDismissesKeyboard(.interactively)
                    CaptureBottomBar(model: model,
                                     pendingActionType: $pendingActionType,
                                     heroCardsDeferred: $heroCardsDeferred,
                                     onCommitSized: commitSizedAction)
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
            #if DEBUG
            if DemoData.isActive && DemoData.route == "capture" && editingHand == nil && stub == nil {
                DemoData.poseMidHand(model)
            }
            #endif
        }
        .sheet(isPresented: $showDictation) {
            DictationSheet { transcript in
                if model.transcript.isEmpty {
                    model.transcript = transcript
                } else {
                    // Dictating again REPLACES the transcript — confirm first
                    // rather than silently discarding what's already there
                    // (setting this presents the replace-confirm dialog).
                    pendingTranscript = transcript
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
            isPresented: Binding(get: { pendingTranscript != nil },
                                 set: { if !$0 { pendingTranscript = nil } }),
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) {
                if let pendingTranscript { model.transcript = pendingTranscript }
                pendingTranscript = nil
            }
            Button("Cancel", role: .cancel) { pendingTranscript = nil }
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
        dismiss()
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
    /// Drives the sheet's dictated-only warning copy (Task 1): true when the
    /// hand has no resolvable structured result, so clearing the transcript
    /// here would leave nothing worth saving.
    let warnIfEmptiedWithoutStructure: Bool
    let onSave: (String) -> Void

    @State private var isExpanded = true
    @State private var showEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
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

                Button {
                    showEditor = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundColor(.goldAccent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit transcript")
            }

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
        .sheet(isPresented: $showEditor) {
            TranscriptEditorSheet(initialText: transcript,
                                 warnIfEmptiedWithoutStructure: warnIfEmptiedWithoutStructure,
                                 onSave: onSave)
        }
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
