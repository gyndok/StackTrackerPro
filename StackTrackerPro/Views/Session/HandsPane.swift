import SwiftUI
import SwiftData

/// Pager pane listing the session's structured hands, with a Log Hand
/// entry point and read-only detail.
struct HandsPane: View {
    let tournament: Tournament?
    let cashSession: CashSession?
    let isReadOnly: Bool

    @Environment(TournamentManager.self) private var tournamentManager
    @Environment(\.modelContext) private var modelContext

    @State private var showEntry = false
    @State private var capturePresentation: CapturePresentation?
    @State private var pendingDeleteHand: Hand?
    @State private var shareHand: Hand?

    private var hands: [Hand] {
        tournament?.sortedHands ?? cashSession?.sortedHands ?? []
    }

    private var pendingStubs: [HandStub] {
        tournament?.pendingStubs ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            if hands.isEmpty && pendingStubs.isEmpty {
                emptyState
            } else {
                List {
                    if !pendingStubs.isEmpty {
                        Section {
                            ForEach(pendingStubs.reversed(), id: \.persistentModelID) { stub in
                                HStack(spacing: 12) {
                                    Button {
                                        guard !isReadOnly else { return }
                                        capturePresentation = CapturePresentation(stub: stub, autoDictate: false)
                                    } label: {
                                        PendingStubRow(stub: stub)
                                    }
                                    .buttonStyle(.plain)

                                    if !isReadOnly {
                                        Button {
                                            capturePresentation = CapturePresentation(stub: stub, autoDictate: true)
                                        } label: {
                                            Label("Dictate Hand", systemImage: "mic.fill")
                                                .labelStyle(.iconOnly)
                                                .foregroundColor(.goldAccent)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .listRowBackground(Color.cardSurface)
                                .swipeActions(edge: .trailing) {
                                    if !isReadOnly {
                                        Button(role: .destructive) {
                                            // Dismiss before deleting: if the chat
                                            // manager still holds this stub as its
                                            // pending swing prompt, dismissing flips
                                            // its status so any interleaved access
                                            // sees a non-pending (not invalidated)
                                            // stub before the hard delete lands.
                                            tournamentManager.dismissStub(stub)
                                            modelContext.delete(stub)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        Button {
                                            tournamentManager.dismissStub(stub)
                                        } label: {
                                            Label("Dismiss", systemImage: "xmark.circle")
                                        }
                                        .tint(.orange)
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text("Pending Hands")
                                Spacer()
                                Text("\(pendingStubs.count)")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.goldAccent))
                                    .foregroundColor(.backgroundPrimary)
                            }
                        }
                    }
                    ForEach(hands.reversed(), id: \.persistentModelID) { hand in
                        NavigationLink {
                            HandDetailView(hand: hand)
                        } label: {
                            HandRow(hand: hand)
                        }
                        .listRowBackground(Color.cardSurface)
                        .swipeActions(edge: .leading) {
                            Button {
                                shareHand = hand
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .tint(.goldAccent)
                        }
                        .swipeActions(edge: .trailing) {
                            if !isReadOnly {
                                Button(role: .destructive) {
                                    pendingDeleteHand = hand
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    capturePresentation = CapturePresentation(edit: hand)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
                // This pane sits behind the session's chat input — dragging
                // the list is the natural keyboard-dismiss gesture (F18).
                .scrollDismissesKeyboard(.interactively)
            }
            if !isReadOnly {
                Button {
                    showEntry = true
                } label: {
                    Label("Log Hand", systemImage: "suit.spade.fill")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.goldAccent)
                        .foregroundColor(.backgroundPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(12)
            }
        }
        .fullScreenCover(isPresented: $showEntry) {
            HandCaptureView(tournament: tournament, cashSession: cashSession, stub: nil) { _ in }
        }
        .fullScreenCover(item: $capturePresentation) { presentation in
            HandCaptureView(tournament: tournament, cashSession: cashSession, stub: presentation.stub,
                            autoStartDictation: presentation.autoDictate,
                            editingHand: presentation.editHand) { _ in }
        }
        .sheet(item: $shareHand) { hand in
            HandSharePreview(hand: hand)
        }
        .confirmationDialog(
            "Delete this hand? This can't be undone.",
            isPresented: Binding(get: { pendingDeleteHand != nil },
                                 set: { if !$0 { pendingDeleteHand = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Hand", role: .destructive) {
                // The Hand → actions / villains relationships cascade on delete.
                if let hand = pendingDeleteHand { modelContext.delete(hand) }
                pendingDeleteHand = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteHand = nil }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "suit.spade")
                .font(.system(size: 40)).foregroundColor(.textSecondary)
                .accessibilityHidden(true)
            Text("No hands logged yet")
                .font(PokerTypography.chipLabel).foregroundColor(.textSecondary)
            Spacer()
        }
    }
}

/// Item for the shared pending-stub capture cover — row-tap presents with
/// `autoDictate: false`, the row's mic accessory with `true`. Wrapping the
/// stub (rather than presenting it directly) lets the same `fullScreenCover`
/// carry that flag without parallel presentation state.
private struct CapturePresentation: Identifiable {
    let id: PersistentIdentifier
    let stub: HandStub?
    let autoDictate: Bool
    let editHand: Hand?

    /// Enrich/dictate a pending stub.
    init(stub: HandStub, autoDictate: Bool) {
        self.id = stub.persistentModelID
        self.stub = stub
        self.autoDictate = autoDictate
        self.editHand = nil
    }

    /// Re-open a saved hand for editing (device finding 16).
    init(edit hand: Hand) {
        self.id = hand.persistentModelID
        self.stub = nil
        self.autoDictate = false
        self.editHand = hand
    }
}

private struct PendingStubRow: View {
    let stub: HandStub

    private var cardsText: String {
        stub.holeCards.isEmpty ? "cards unknown" : HoleCardShorthand.display(stub.holeCards)
    }

    private var quickChipsText: String {
        var text = stub.quickResult?.rawValue ?? ""
        if let villain = stub.quickVillain {
            text += text.isEmpty ? villain.rawValue : " \(villain.rawValue)"
        }
        return text
    }

    private var originIcon: String {
        switch stub.origin {
        case .swingDetected: return "bolt.fill"
        case .breakDebrief: return "cup.and.saucer.fill"
        case .manual: return "suit.spade.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: originIcon)
                    .foregroundColor(.goldAccent)
                    .accessibilityHidden(true)
                Text(cardsText)
                    .font(PokerTypography.statValue)
                    .foregroundColor(stub.holeCards.isEmpty ? .textSecondary : .textPrimary)
                Spacer()
                if stub.levelNumber > 0 {
                    Text("L\(stub.levelNumber)")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)
                }
            }
            HStack(spacing: 4) {
                if stub.heroStackBefore > 0 {
                    Text(stub.heroStackBefore.formatted())
                }
                if !quickChipsText.isEmpty {
                    Text("· \(quickChipsText)")
                }
                Spacer()
                Text(stub.createdAt, style: .relative)
            }
            .font(PokerTypography.chatCaption)
            .foregroundColor(.textSecondary)
        }
        .contentShape(Rectangle())
    }
}

private struct HandRow: View {
    let hand: Hand

    /// A hand with no recorded ledger but a dictated transcript renders
    /// without a result — there is nothing structured to book (Task 2's
    /// "Dictated" rendering rule).
    private var isDictatedOnly: Bool {
        hand.sortedActions.isEmpty && !hand.notes.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(hand.heroPosition.rawValue)
                    .font(PokerTypography.chipLabel).foregroundColor(.goldAccent)
                ForEach(hand.heroCards, id: \.self) { card in
                    Text(card.display)
                        .font(PokerTypography.statValue)
                        .foregroundColor(card.isRed ? .red : .textPrimary)
                }
                Spacer()
                if isDictatedOnly {
                    Text("Dictated")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)
                } else {
                    Text(hand.result.rawValue)
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(hand.result == .won ? .green : (hand.result == .lost ? .red : .textSecondary))
                }
            }
            HStack {
                Text(hand.timestamp.formatted(date: .omitted, time: .shortened))
                if !hand.blindsDisplay.isEmpty { Text("· \(hand.blindsDisplay)") }
                if !isDictatedOnly, hand.amountWon != 0 {
                    Text("· \(hand.amountWon > 0 ? "+" : "")\(hand.amountWon.formatted())")
                }
            }
            .font(PokerTypography.chatCaption)
            .foregroundColor(.textSecondary)
        }
    }
}

struct HandDetailView: View {
    let hand: Hand

    @State private var showShare = false

    /// A hand with no recorded ledger but a dictated transcript has nothing
    /// structured to report — the Result section is suppressed (Task 2).
    private var isDictatedOnly: Bool {
        hand.sortedActions.isEmpty && !hand.notes.isEmpty
    }

    var body: some View {
        ZStack {
            Color.backgroundPrimary.ignoresSafeArea()
            List {
                Section("Context") {
                    row("Position", hand.heroPosition.rawValue)
                    if hand.levelNumber > 0 { row("Level", "\(hand.levelNumber)") }
                    if !hand.blindsDisplay.isEmpty { row("Blinds", hand.blindsDisplay) }
                    if hand.heroStackChips > 0 { row("Stack", hand.heroStackChips.formatted()) }
                    if hand.playersRemaining > 0 { row("Players left", "\(hand.playersRemaining)") }
                }
                Section("Cards") {
                    row("Hole cards", hand.heroCards.map(\.display).joined(separator: " "))
                    if !hand.board.isEmpty {
                        row("Board", hand.board.map(\.display).joined(separator: " "))
                    }
                    if !hand.villainCards.isEmpty {
                        row("Villain", hand.villainCards.map(\.display).joined(separator: " "))
                    }
                }
                if !hand.sortedVillains.isEmpty {
                    Section("Villains") {
                        ForEach(hand.sortedVillains, id: \.persistentModelID) { villain in
                            row(villain.chipLabel,
                                villain.shownCards.isEmpty ? "—" : villain.shownCards.map(\.display).joined(separator: " "))
                        }
                    }
                }
                ForEach(HandStreet.allCases, id: \.self) { street in
                    let actions = hand.sortedActions.filter { $0.street == street }
                    if !actions.isEmpty {
                        Section(street.label) {
                            ForEach(actions, id: \.persistentModelID) { action in
                                HStack {
                                    Text(action.timelineDescription)
                                        .foregroundColor(action.isHero ? .goldAccent : .textPrimary)
                                    Spacer()
                                    if action.isHero {
                                        Text("you").font(PokerTypography.chatCaption).foregroundColor(.textSecondary)
                                    }
                                }
                                .listRowBackground(Color.cardSurface)
                            }
                        }
                    }
                }
                if !isDictatedOnly {
                    Section("Result") {
                        row("Outcome", hand.result.rawValue)
                        if hand.potSize > 0 { row("Pot", hand.potSize.formatted()) }
                        if hand.amountWon != 0 { row("Net", hand.amountWon.formatted()) }
                        if hand.heroStackAfter > 0 { row("Stack after", hand.heroStackAfter.formatted()) }
                        if !hand.tags.isEmpty { row("Tags", hand.tags.joined(separator: ", ")) }
                    }
                }
                if !hand.notes.isEmpty {
                    Section("Transcript") {
                        Text(hand.notes)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.textPrimary)
                            .listRowBackground(Color.cardSurface)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Hand")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showShare = true
                } label: {
                    Label("Share Hand", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showShare) {
            HandSharePreview(hand: hand)
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.textSecondary)
            Spacer()
            Text(value).foregroundColor(.textPrimary).multilineTextAlignment(.trailing)
        }
        .listRowBackground(Color.cardSurface)
    }
}
