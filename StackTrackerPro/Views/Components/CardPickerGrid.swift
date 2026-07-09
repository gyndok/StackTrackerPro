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
                ForEach(Array("shdc"), id: \.self) { suit in
                    let card = pendingRank.flatMap { PlayingCard(rank: $0, suit: suit) }
                    Button {
                        if let card { onPick(card); pendingRank = nil }
                    } label: {
                        Text(suitSymbol(suit))
                            .font(.title2)
                            .foregroundColor(suit == "h" || suit == "d" ? .red : .primary)
                            .frame(width: 52, height: 40)
                    }
                    .buttonStyle(.bordered)
                    .disabled(pendingRank == nil || card == nil || dealt.contains(card!))
                }
            }
        }
    }

    private func suitSymbol(_ s: Character) -> String {
        switch s {
        case "s": return "♠"
        case "h": return "♥"
        case "d": return "♦"
        default: return "♣"
        }
    }
}

#Preview {
    CardPickerGrid(dealt: []) { _ in }
        .padding()
        .background(Color.backgroundPrimary)
}
