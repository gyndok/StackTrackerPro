import SwiftUI

/// The pinned control surface under the capture scroll view (spec §1). One
/// state at a time, derived from the engine by `CaptureBarState.derive`; this
/// view only renders that state and forwards taps.
struct CaptureBottomBar: View {
    let model: HandCaptureModel
    @Binding var pendingActionType: HandActionType?
    @Binding var heroCardsDeferred: Bool
    let onCommitSized: (HandActionType, Int) -> Void

    private var state: CaptureBarState {
        CaptureBarState.derive(
            isHandOver: model.isHandOver,
            boardCardsNeeded: model.boardCardsNeeded,
            streetBeingDealt: model.streetBeingDealt,
            pendingAction: pendingActionType,
            heroCardsMissing: model.heroCards.count < model.heroCardCount,
            heroCardsDeferred: heroCardsDeferred,
            ledgerIsEmpty: model.ledger.isEmpty,
            villainsIsEmpty: model.villains.isEmpty)
    }

    var body: some View {
        switch state {
        case .done:
            EmptyView()
        case .needsVillain:
            barChrome {
                Text("Add a villain to start the hand")
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        case .acting:
            barChrome {
                ContextStrip(model: model)
                ActionButtons(model: model, pendingActionType: $pendingActionType)
            }
        case .sizing(let type):
            barChrome {
                ContextStrip(model: model)
                SizingPanel(model: model, actionType: type,
                            onCommit: onCommitSized,
                            onCancel: { pendingActionType = nil })
            }
        case .dealingBoard(let street, let needed):
            barChrome {
                DealingPanel(
                    title: "\(street.label) card\(needed > 1 ? "s (\(needed))" : "")",
                    cards: model.board,
                    removableLast: model.lastInputWasBoardCard,
                    dealt: model.dealtCards,
                    onPick: { if model.addBoardCard($0) { HapticFeedback.impact(.light) } },
                    onRemoveLast: { model.undoLast() },
                    trailing: nil)
            }
        case .dealingHero:
            barChrome {
                DealingPanel(
                    title: "Your cards",
                    cards: model.heroCards,
                    removableLast: !model.heroCards.isEmpty,
                    dealt: model.dealtCards,
                    onPick: { if model.addCard($0) { HapticFeedback.impact(.light) } },
                    onRemoveLast: { model.heroCards.removeLast() },
                    trailing: ("Later", { heroCardsDeferred = true }))
            }
        }
    }

    private func barChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background(Color.cardSurface.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Rectangle().fill(Color.goldAccent).frame(height: 1.5) }
    }
}

// MARK: - Context strip

/// `STREET · board so far · Pot N` — always visible while acting/sizing so
/// the user never scrolls up to check the board before sizing (spec §1).
/// The last board card is removable only when it is genuinely the last
/// input (`lastInputWasBoardCard`), same rule the old Board section used.
struct ContextStrip: View {
    let model: HandCaptureModel

    var body: some View {
        HStack(spacing: 8) {
            Text(model.currentStreet.label.uppercased())
                .font(PokerTypography.chipLabel.weight(.bold))
                .foregroundColor(.goldAccent)
            ForEach(model.board, id: \.self) { card in
                MiniCard(card: card,
                         onRemove: (card == model.board.last && model.lastInputWasBoardCard)
                            ? { model.undoLast() } : nil)
            }
            Spacer(minLength: 4)
            Text("Pot \(model.pot.formatted())")
                .font(PokerTypography.chipLabel.weight(.semibold))
                .foregroundColor(.textPrimary)
        }
    }
}

/// Small board-card chip used by the strip and the dealing panels.
struct MiniCard: View {
    let card: PlayingCard
    var onRemove: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(card.display)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(card.isRed ? .red : .textPrimary)
                .frame(width: 34, height: 40)
                .background(Color.backgroundPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.chipRed)
                        .background(Circle().fill(Color.backgroundPrimary))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel("Remove \(card.display)")
            }
        }
    }
}

// MARK: - Action buttons

/// Legal actions for whoever is to act. Semantics are the old `ActionRow`'s,
/// verbatim: fold/check/call commit at once; bet/raise open sizing; all-in
/// commits the jam when the stack is known, else opens sizing as `.allIn`.
private struct ActionButtons: View {
    let model: HandCaptureModel
    @Binding var pendingActionType: HandActionType?

    var body: some View {
        if let actor = model.participantToAct {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(model.label(for: actor)) to act")
                    .font(PokerTypography.sectionHeader)
                    .foregroundColor(.goldAccent)
                HStack(spacing: 8) {
                    ForEach(model.legalActions, id: \.self) { action in
                        Button {
                            handle(action)
                        } label: {
                            Text(buttonLabel(action))
                                .font(PokerTypography.statValue)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(Color.backgroundPrimary)
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
            guard let actor = model.participantToAct else { return }
            if let jam = model.jamTotal(for: actor) {
                model.add(action: .allIn, toAmount: jam)
                HapticFeedback.impact(.light)
            } else {
                pendingActionType = .allIn
            }
        }
    }
}

// MARK: - Sizing panel (chips ⇄ keypad)

private struct SizingPanel: View {
    let model: HandCaptureModel
    let actionType: HandActionType
    let onCommit: (HandActionType, Int) -> Void
    let onCancel: () -> Void

    @State private var showKeypad = false

    private var chips: [SizingPresets.Chip] {
        let actor = model.participantToAct
        return SizingPresets.chips(
            street: model.currentStreet,
            currentBet: model.currentBet,
            minRaiseTotal: model.minRaiseTotal,
            pot: model.pot,
            bigBlind: model.bigBlind,
            jamTotal: actor.flatMap { model.jamTotal(for: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(PokerTypography.sectionHeader).foregroundColor(.goldAccent)
                Spacer()
                Button("Cancel", action: onCancel)
                    .font(.caption)
                    .foregroundColor(.textSecondary)
            }
            if showKeypad {
                SizingKeypad(actionType: actionType, bigBlind: model.bigBlind,
                             onCommit: { onCommit(actionType, $0) },
                             onBack: { showKeypad = false })
            } else {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.label) { chip in
                        Button(chip.label) { onCommit(actionType, chip.toAmount) }
                            .buttonStyle(.bordered)
                            .tint(.secondary)
                            .disabled(!chip.isEnabled)
                    }
                    Button("Jam") { commitJam() }
                        .buttonStyle(.bordered)
                        .tint(.chipRed)
                    Button("#") { showKeypad = true }
                        .buttonStyle(.bordered)
                        .tint(.goldAccent)
                }
                // With no numeric blinds (a cash session whose stakes text
                // didn't parse) every preset is 0 and disabled — say why,
                // rather than show a row of dead chips.
                if model.bigBlind == 0 {
                    Text("Set numeric stakes on this session to use presets")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)
                }
            }
        }
    }

    private var title: String {
        guard let actor = model.participantToAct else { return "Size" }
        let verb: String
        switch actionType {
        case .raise: verb = "raise"
        case .allIn: verb = "all-in"
        default: verb = "bet"
        }
        return "\(model.label(for: actor)) — \(verb) size"
    }

    private func commitJam() {
        guard let actor = model.participantToAct else { return }
        if let jam = model.jamTotal(for: actor) {
            onCommit(.allIn, jam)
        } else {
            showKeypad = true
        }
    }
}

/// Inline amount entry (spec §3). No TextField: the system keyboard never
/// appears from the bar. Keys append to a raw string parsed by
/// `SizingInput.parse` (literal chips, `k`, `bb`); the confirm button previews
/// exactly what will be committed.
private struct SizingKeypad: View {
    let actionType: HandActionType
    let bigBlind: Int
    let onCommit: (Int) -> Void
    let onBack: () -> Void

    @State private var text = ""

    private static let rows: [[String]] = [["1", "2", "3", "4", "5"], ["6", "7", "8", "9", "0"], ["k", "bb", "⌫"]]

    private var resolved: Int? { SizingInput.parse(text, bigBlind: bigBlind) }

    private var confirmLabel: String {
        let verb: String
        switch actionType {
        case .raise: verb = "Raise to"
        case .allIn: verb = "All-in"
        default: verb = "Bet"
        }
        guard let resolved else { return verb }
        return "\(verb) \(resolved.formatted())"
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(text.isEmpty ? "e.g. 2300, 4bb, 42k" : text)
                    .font(.system(.title3, design: .monospaced))
                    .foregroundColor(text.isEmpty ? .textSecondary : .textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.backgroundPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Button("Chips", action: onBack)
                    .font(.caption)
                    .foregroundColor(.textSecondary)
            }
            ForEach(Self.rows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { key in
                        Button {
                            press(key)
                        } label: {
                            Text(key)
                                .font(PokerTypography.statValue)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(Color.backgroundPrimary)
                                .foregroundColor(key == "⌫" ? .chipRed : .textPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(key == "⌫" ? "Delete" : key)
                    }
                    if row.count < 5 {
                        Button(confirmLabel) {
                            if let resolved { onCommit(resolved) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.goldAccent)
                        .disabled(resolved == nil)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func press(_ key: String) {
        switch key {
        case "⌫":
            if !text.isEmpty { text.removeLast() }
        case "k", "bb":
            // One suffix at a time: replace any existing suffix.
            let digits = text.filter { $0.isNumber || $0 == "." }
            text = digits + key
        default:
            // Typing a digit after a suffix means a fresh number.
            if text.hasSuffix("k") || text.hasSuffix("bb") { text = "" }
            text.append(key)
        }
    }
}

// MARK: - Dealing panel

/// Card entry inside the bar (spec §1 dealing states): the cards so far as
/// mini chips (last one removable when the caller allows), then the grid.
/// `trailing` is an optional header action — the hero-cards "Later" link.
private struct DealingPanel: View {
    let title: String
    let cards: [PlayingCard]
    let removableLast: Bool
    let dealt: Set<PlayingCard>
    let onPick: (PlayingCard) -> Void
    let onRemoveLast: () -> Void
    let trailing: (String, () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(PokerTypography.sectionHeader).foregroundColor(.goldAccent)
                if !cards.isEmpty {
                    ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                        MiniCard(card: card,
                                 onRemove: (index == cards.count - 1 && removableLast) ? onRemoveLast : nil)
                    }
                }
                Spacer()
                if let trailing {
                    Button(trailing.0, action: trailing.1)
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                }
            }
            CardGrid(dealt: dealt, onPick: onPick)
        }
    }
}
