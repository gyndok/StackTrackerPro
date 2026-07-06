import SwiftUI
import SwiftData

/// Staged, tap-only hand entry ("the keyboard"). Presented as a sheet from
/// an active tournament or cash session; context is snapshotted on save.
struct HandEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let tournament: Tournament?
    let cashSession: CashSession?

    @State private var model = HandEntryModel()
    @AppStorage(SettingsKeys.defaultSeatsPerTable) private var seatsDefault = 9

    var body: some View {
        NavigationStack {
            ZStack {
                Color.backgroundPrimary.ignoresSafeArea()
                VStack(spacing: 0) {
                    entryBar
                    Divider().background(Color.cardSurface)
                    stageSurface
                }
            }
            .navigationTitle("Log Hand")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.textSecondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .foregroundColor(.goldAccent)
                    }
                    .accessibilityLabel("Undo last input")
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(model.stage != .position)
    }

    // MARK: - Entry bar (always visible: cards + timeline)

    private var entryBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let position = model.heroPosition {
                    Text(position.rawValue)
                        .font(PokerTypography.chipLabel)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.goldAccent.opacity(0.25))
                        .clipShape(Capsule())
                        .foregroundColor(.goldAccent)
                }
                ForEach(model.heroCards, id: \.self) { CardChip(card: $0) }
                if !model.board.isEmpty {
                    Text("|").foregroundColor(.textSecondary)
                    ForEach(model.board, id: \.self) { CardChip(card: $0) }
                }
                Spacer()
            }
            if !model.timeline.isEmpty {
                Text(model.timeline)
                    .font(PokerTypography.chatCaption)
                    .foregroundColor(.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
    }

    // MARK: - Stage surfaces

    @ViewBuilder
    private var stageSurface: some View {
        switch model.stage {
        case .position:
            positionPad
        case .holeCards:
            cardPicker(title: "Your hole cards")
        case .boardCards(let street):
            cardPicker(title: "\(street.label) card\(street == .flop ? "s" : "")")
        case .action(let street):
            actionPad(street: street)
        case .result:
            resultForm
        }
    }

    private var positionPad: some View {
        VStack(spacing: 16) {
            Text("Your position")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(HeroPosition.allCases, id: \.self) { position in
                    Button {
                        model.selectPosition(position)
                        HapticFeedback.impact(.light)
                    } label: {
                        Text(position.rawValue)
                            .font(PokerTypography.statValue)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(Color.cardSurface)
                            .foregroundColor(.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(.horizontal, 16)
            Spacer()
        }
        .padding(.top, 24)
    }

    private func cardPicker(title: String) -> some View {
        VStack(spacing: 14) {
            Text(title)
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
            RankSuitPicker { card in
                if model.addCard(card) { HapticFeedback.impact(.light) }
            } isDealt: { model.isCardDealt($0) }
            if model.heroCards.count == 2 {
                Button("Skip board, finish hand") { model.finishHand() }
                    .foregroundColor(.textSecondary)
            }
            Spacer()
        }
        .padding(.top, 24)
    }

    private func actionPad(street: HandStreet) -> some View {
        VStack(spacing: 14) {
            Text("\(street.label) action")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)

            // Acting position selector (hero highlighted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(HeroPosition.allCases, id: \.self) { position in
                        let isActing = model.actingPosition == position
                        let isHero = model.heroPosition == position
                        Button {
                            model.actingPosition = position
                        } label: {
                            Text(position.rawValue)
                                .font(PokerTypography.chipLabel)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(isActing ? Color.goldAccent : Color.cardSurface)
                                .foregroundColor(isActing ? .backgroundPrimary : (isHero ? .goldAccent : .textPrimary))
                                .clipShape(Capsule())
                        }
                        .accessibilityLabel("\(position.rawValue)\(isHero ? ", you" : "")\(isActing ? ", acting" : "")")
                    }
                }
                .padding(.horizontal, 16)
            }

            ActionButtons { type, amount in
                model.addAction(type, amount: amount)
                HapticFeedback.impact(.light)
            } bigBlind: {
                tournament?.currentBlinds?.bigBlind ?? 0
            } potEstimate: {
                model.potEstimate(
                    sb: tournament?.currentBlinds?.smallBlind ?? 0,
                    bb: tournament?.currentBlinds?.bigBlind ?? 0,
                    ante: tournament?.currentBlinds?.ante ?? 0
                )
            }

            HStack(spacing: 12) {
                if street != .river {
                    Button {
                        model.advanceStreet()
                    } label: {
                        Text("Next Street")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color.goldAccent)
                            .foregroundColor(.backgroundPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                Button {
                    model.finishHand()
                } label: {
                    Text("Finish Hand")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color.cardSurface)
                        .foregroundColor(.goldAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, 16)
            Spacer()
        }
        .padding(.top, 24)
    }

    private var resultForm: some View {
        Form {
            Section("Result") {
                Picker("Outcome", selection: Binding(
                    get: { model.result ?? .folded },
                    set: { model.result = $0 }
                )) {
                    ForEach(HandResult.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Pot").foregroundColor(.textSecondary)
                    Spacer()
                    TextField("0", value: $model.potSize, format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Net won/lost").foregroundColor(.textSecondary)
                    Spacer()
                    TextField("0", value: $model.amountWon, format: .number)
                        .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                }
            }
            Section("Tags") {
                FlowTags(all: HandEntryModel.presetTags, selected: $model.selectedTags)
            }
            Section("Notes") {
                TextField("Optional note", text: $model.notes, axis: .vertical).lineLimit(2...4)
            }
            Section {
                Button {
                    _ = model.save(into: modelContext,
                                   tournament: tournament,
                                   cashSession: cashSession,
                                   seatsDefault: seatsDefault)
                    try? modelContext.save()
                    HapticFeedback.success()
                    dismiss()
                } label: {
                    Text("Save Hand")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .foregroundColor(.goldAccent)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            if model.potSize == 0 {
                model.potSize = model.potEstimate(
                    sb: tournament?.currentBlinds?.smallBlind ?? 0,
                    bb: tournament?.currentBlinds?.bigBlind ?? 0,
                    ante: tournament?.currentBlinds?.ante ?? 0
                )
            }
        }
    }
}

// MARK: - Components

private struct CardChip: View {
    let card: PlayingCard
    var body: some View {
        Text(card.display)
            .font(PokerTypography.statValue)
            .foregroundColor(card.isRed ? .red : .textPrimary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.backgroundPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct RankSuitPicker: View {
    let onCard: (PlayingCard) -> Void
    let isDealt: (PlayingCard) -> Bool

    @State private var pendingRank: Character?

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(PlayingCard.ranks, id: \.self) { rank in
                    Button {
                        pendingRank = rank
                        HapticFeedback.impact(.light)
                    } label: {
                        Text(String(rank))
                            .font(PokerTypography.statValue)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(pendingRank == rank ? Color.goldAccent : Color.cardSurface)
                            .foregroundColor(pendingRank == rank ? .backgroundPrimary : .textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            HStack(spacing: 10) {
                ForEach(PlayingCard.suits, id: \.self) { suit in
                    let card = pendingRank.flatMap { PlayingCard(rank: $0, suit: suit) }
                    let disabled = card == nil || (card.map(isDealt) ?? true)
                    Button {
                        if let card { onCard(card); pendingRank = nil }
                    } label: {
                        Text(PlayingCard(rank: "A", suit: suit)!.suitSymbol)
                            .font(.system(size: 28))
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Color.cardSurface)
                            .foregroundColor(suit == "h" || suit == "d" ? .red : .textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .opacity(disabled ? 0.3 : 1)
                    }
                    .disabled(disabled)
                    .accessibilityLabel("Suit \(PlayingCard(rank: "A", suit: suit)!.suitSymbol)")
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

private struct ActionButtons: View {
    let onAction: (HandActionType, Int) -> Void
    let bigBlind: () -> Int
    let potEstimate: () -> Int

    @State private var pendingSize = 0
    @State private var showSizeEntry = false
    @State private var pendingType: HandActionType?

    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(HandActionType.allCases, id: \.self) { type in
                    Button {
                        switch type {
                        case .fold, .check:
                            onAction(type, 0)
                        case .call, .bet, .raise, .allIn:
                            pendingType = type
                            pendingSize = 0
                            showSizeEntry = true
                        }
                    } label: {
                        Text(type.rawValue)
                            .font(PokerTypography.statValue)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Color.cardSurface)
                            .foregroundColor(.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .alert("Amount", isPresented: $showSizeEntry) {
            TextField("Chips", value: $pendingSize, format: .number)
                .keyboardType(.numberPad)
            Button("2.5x BB") { commit(bigBlind() * 5 / 2) }
            Button("Pot") { commit(potEstimate()) }
            Button("OK") { commit(pendingSize) }
            Button("Cancel", role: .cancel) { pendingType = nil }
        } message: {
            Text("Enter the amount, or use a quick size.")
        }
    }

    private func commit(_ amount: Int) {
        if let type = pendingType { onAction(type, max(0, amount)) }
        pendingType = nil
    }
}

private struct FlowTags: View {
    let all: [String]
    @Binding var selected: Set<String>

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
            ForEach(all, id: \.self) { tag in
                let isOn = selected.contains(tag)
                Button {
                    if isOn { selected.remove(tag) } else { selected.insert(tag) }
                } label: {
                    Text(tag)
                        .font(PokerTypography.chipLabel)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(isOn ? Color.goldAccent.opacity(0.3) : Color.cardSurface)
                        .foregroundColor(isOn ? .goldAccent : .textPrimary)
                        .clipShape(Capsule())
                }
            }
        }
    }
}
