import SwiftUI

/// Two-tap card picker: tap a rank then a suit. Already-dealt cards are
/// rejected (button disabled). 13 ranks over two rows + one suit row.
struct CardPickerGrid: View {
    let dealt: Set<PlayingCard>
    let onPick: (PlayingCard) -> Void

    @State private var pendingRank: Character?

    private static let rankRows: [[Character]] = [
        ["A", "K", "Q", "J", "T", "9", "8", "7"],
        ["6", "5", "4", "3", "2"],
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Self.rankRows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { rank in
                        Button(rank == "T" ? "10" : String(rank)) {
                            pendingRank = rank
                        }
                        .buttonStyle(.bordered)
                        .tint(pendingRank == rank ? .goldAccent : .secondary)
                    }
                }
            }
            HStack(spacing: 10) {
                ForEach(Array("shdcx"), id: \.self) { suit in
                    let card = pendingRank.flatMap { PlayingCard(rank: $0, suit: suit) }
                    Button {
                        if let card { onPick(card); pendingRank = nil }
                    } label: {
                        Text(suitSymbol(suit))
                            .font(.title2)
                            .foregroundColor(suitColor(suit))
                            .frame(width: 52, height: 40)
                    }
                    .buttonStyle(.bordered)
                    // Real suits stay deduped against already-dealt cards; the
                    // unknown-suit card is never disabled by dedup (Kx and Kx
                    // can both be "in play" — the whole point is nobody knows
                    // the real suit, so there is nothing to collide on).
                    .disabled(pendingRank == nil || card == nil || (!card!.hasUnknownSuit && dealt.contains(card!)))
                }
            }
        }
    }

    private func suitSymbol(_ s: Character) -> String {
        switch s {
        case "s": return "♠"
        case "h": return "♥"
        case "d": return "♦"
        case "x": return "x"
        default: return "♣"
        }
    }

    private func suitColor(_ s: Character) -> Color {
        switch s {
        case "h", "d": return .red
        case "x": return .secondary
        default: return .primary
        }
    }
}

#Preview {
    CardPickerGrid(dealt: []) { _ in }
        .padding()
        .background(Color.backgroundPrimary)
}
