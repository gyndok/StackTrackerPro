import SwiftUI
import SwiftData

/// Session-level VPIP/PFR from structured hands. Pure, unit-tested.
enum HandStats {
    static func vpipPercent(_ hands: [Hand]) -> Double {
        guard !hands.isEmpty else { return 0 }
        let vpip = hands.filter { hand in
            hand.heroPreflopActions.contains { $0.actionType.isVoluntaryChips }
        }.count
        return Double(vpip) / Double(hands.count) * 100
    }

    static func pfrPercent(_ hands: [Hand]) -> Double {
        guard !hands.isEmpty else { return 0 }
        let pfr = hands.filter { hand in
            hand.heroPreflopActions.contains { $0.actionType == .raise || $0.actionType == .allIn }
        }.count
        return Double(pfr) / Double(hands.count) * 100
    }
}

/// Pager pane listing the session's structured hands, with a Log Hand
/// entry point and read-only detail.
struct HandsPane: View {
    let tournament: Tournament?
    let cashSession: CashSession?
    let isReadOnly: Bool

    @State private var showEntry = false

    private var hands: [Hand] {
        tournament?.sortedHands ?? cashSession?.sortedHands ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            statsHeader
            if hands.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(hands.reversed(), id: \.persistentModelID) { hand in
                        NavigationLink {
                            HandDetailView(hand: hand)
                        } label: {
                            HandRow(hand: hand)
                        }
                        .listRowBackground(Color.cardSurface)
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
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
        .sheet(isPresented: $showEntry) {
            HandEntryView(tournament: tournament, cashSession: cashSession)
        }
    }

    private var statsHeader: some View {
        HStack(spacing: 16) {
            stat("Hands", "\(hands.count)")
            stat("VPIP", hands.isEmpty ? "---" : String(format: "%.0f%%", HandStats.vpipPercent(hands)))
            stat("PFR", hands.isEmpty ? "---" : String(format: "%.0f%%", HandStats.pfrPercent(hands)))
        }
        .padding(12)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(PokerTypography.chipLabel).foregroundColor(.textSecondary)
            Text(value).font(PokerTypography.statValue).foregroundColor(.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

private struct HandRow: View {
    let hand: Hand

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
                Text(hand.result.rawValue)
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(hand.result == .won ? .green : (hand.result == .lost ? .red : .textSecondary))
            }
            HStack {
                Text(hand.timestamp.formatted(date: .omitted, time: .shortened))
                if !hand.blindsDisplay.isEmpty { Text("· \(hand.blindsDisplay)") }
                if hand.amountWon != 0 {
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
                Section("Result") {
                    row("Outcome", hand.result.rawValue)
                    if hand.potSize > 0 { row("Pot", hand.potSize.formatted()) }
                    if hand.amountWon != 0 { row("Net", hand.amountWon.formatted()) }
                    if !hand.tags.isEmpty { row("Tags", hand.tags.joined(separator: ", ")) }
                    if !hand.notes.isEmpty { row("Notes", hand.notes) }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Hand")
        .navigationBarTitleDisplayMode(.inline)
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
