import SwiftUI

// MARK: - Position grid

/// Shared 3-column, 9-seat position picker used for both the hero's seat
/// (`HeroSetupSection`) and a villain's seat (`VillainInlineEditor`, which
/// disables whichever seat the hero already occupies).
struct PositionGrid: View {
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

// MARK: - Card chip

/// A single dealt/held card rendered as a chip — the shared look used for the
/// hero's hole cards and a villain's shown holding. An optional trailing "x"
/// removes the card via `onRemove` when the caller allows it. (The board row
/// now lives in the bar as `ContextStrip`/`MiniCard` — see
/// `CaptureBottomBar.swift`.)
struct CardChip: View {
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

// MARK: - Hero (collapsed chips)

/// Hero setup as a chip row once set (spec §5): `[BTN] [A♥ K♦] [42,500 ✎]`.
/// Seat chip toggles the position grid inline; cards chip clears the hero
/// cards (a fresh hand re-enters the bar's dealing state, a hand in flight
/// shows the grid inline); stack chip opens the existing stack alert.
struct HeroSetupSection: View {
    let model: HandCaptureModel
    let stubHint: String?
    @Binding var heroCardsDeferred: Bool
    @Binding var showStackPad: Bool
    @Binding var stackPadText: String

    @State private var showSeatGrid = false

    private var chips: CaptureChips.Hero {
        CaptureChips.hero(position: model.heroPosition, cards: model.heroCards,
                          cardCount: model.heroCardCount, stack: model.heroStackBefore)
    }

    private var cardsMissing: Bool { model.heroCards.count < model.heroCardCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hero").font(PokerTypography.sectionHeader).foregroundColor(.goldAccent)
            HStack(spacing: 8) {
                Button(chips.seat) { showSeatGrid.toggle() }
                    .quickChip()
                    .accessibilityLabel("Hero seat \(chips.seat), change")
                Button {
                    guard !model.heroCards.isEmpty else { return }
                    // Mirror addCard's invalidation: card evidence changed.
                    model.heroCards.removeAll()
                    model.winnerOverride = nil
                    model.potOverride = nil
                    heroCardsDeferred = false
                } label: {
                    Text(chips.cards)
                }
                .quickChip()
                .accessibilityLabel("Hero cards \(chips.cards), re-enter")
                Button {
                    stackPadText = String(model.heroStackBefore)
                    showStackPad = true
                } label: {
                    HStack(spacing: 4) {
                        Text(chips.stack)
                        Image(systemName: "pencil").font(.caption2)
                    }
                }
                .quickChip()
                .accessibilityLabel("Stack at start of hand, \(chips.stack), edit")
                Spacer()
            }
            if let stubHint, cardsMissing {
                Text("Stub: \(stubHint)")
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(.textSecondary)
            }
            if showSeatGrid || model.heroPosition == nil {
                PositionGrid(selected: model.heroPosition) { position in
                    model.heroPosition = position
                    showSeatGrid = false
                    HapticFeedback.impact(.light)
                }
            }
            // Inline card entry is the complement of the bar's dealingHero
            // state: a hand already in flight, or a deferred fresh hand.
            if cardsMissing && (!model.ledger.isEmpty || heroCardsDeferred) {
                CardGrid(dealt: model.dealtCards) { card in
                    if model.addCard(card) { HapticFeedback.impact(.light) }
                }
            }
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
        .pokerCard()
    }
}

// MARK: - Villain editor target

/// Which inline villain editor is expanded, if any: a fresh add, or an
/// existing villain re-opened for editing.
enum VillainEditorTarget: Hashable {
    case adding
    case editing(UUID)
}

// MARK: - Villains

/// Villain rows + add/edit editor, moved out of HandCaptureView unchanged in
/// behavior. Owns villain removal end to end, including the confirmation
/// dialog for a removal that drops recorded actions or collapses the hand.
struct VillainSection: View {
    let model: HandCaptureModel
    @Binding var villainEditorTarget: VillainEditorTarget?
    @Binding var shownCardsTarget: UUID?

    @State private var pendingRemovalID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Villains").font(PokerTypography.sectionHeader).foregroundColor(.goldAccent)
                Spacer()
                Button {
                    villainEditorTarget = villainEditorTarget == .adding ? nil : .adding
                } label: {
                    Label("Add villain", systemImage: "plus.circle")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.goldAccent)
                }
            }
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
                        Text(chipText(villain))
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
                            remove(villain.id)
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .foregroundColor(.chipRed)
                    .accessibilityLabel("Remove villain")
                }
                if shownCardsTarget == villain.id {
                    VillainShownCardsEditor(model: model, villainID: villain.id) {
                        shownCardsTarget = nil
                    }
                }
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
        .confirmationDialog(
            removalDialogTitle,
            isPresented: Binding(get: { pendingRemovalID != nil }, set: { if !$0 { pendingRemovalID = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Villain", role: .destructive) {
                if let id = pendingRemovalID { remove(id) }
                pendingRemovalID = nil
            }
            Button("Cancel", role: .cancel) { pendingRemovalID = nil }
        }
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

    /// Same single removal path as before: close any editor still pointed
    /// at the villain before dropping them.
    func remove(_ id: UUID) {
        if villainEditorTarget == .editing(id) { villainEditorTarget = nil }
        if shownCardsTarget == id { shownCardsTarget = nil }
        model.removeVillain(id: id)
    }

    private func editing(for target: VillainEditorTarget) -> HandCaptureModel.VillainDraft? {
        guard case .editing(let id) = target else { return nil }
        return model.villains.first { $0.id == id }
    }

    private func chipText(_ villain: HandCaptureModel.VillainDraft) -> String {
        var text = model.label(for: .villain(villain.id))
        if villain.approxStack > 0 { text += " ≈\(villain.approxStack.formatted())" }
        if villain.shownHolding.count == 2 {
            text += " " + villain.shownHolding.map(\.display).joined(separator: " ")
        } else if villain.mucked {
            text += " (mucked)"
        }
        return text
    }
}

/// Inline villain add/edit form. Every control SELECTS (position, relative
/// stack, optional approx stack) and nothing commits until the explicit
/// primary button ("Add Villain" / "Done") — the earlier tap-a-stack-chip-to-
/// commit flow stranded anyone who typed the stack amount first and left no
/// discoverable way to finish (device finding 6).
struct VillainInlineEditor: View {
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
                // Content is gated on THIS field's focus: another inline
                // TextField mounted alongside this editor would have its
                // keyboard toolbar concatenated onto this one by SwiftUI —
                // ungated, two Done buttons would appear.
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
/// (see `VillainSection`), not the position/stack editor, which locks after
/// `hasActed` since it replaces the villain's identity.
struct VillainShownCardsEditor: View {
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
                CardGrid(dealt: model.dealtCards) { card in
                    guard let current = self.villain else { return }
                    model.setShownHolding(current.shownHolding + [card], for: villainID)
                }
            }
        }
        .padding(.top, 4)
    }
}
