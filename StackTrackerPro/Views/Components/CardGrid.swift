import SwiftUI

/// One-tap card picker (spec §2): five rows — ♠ ♥ ♦ ♣ and an unknown-suit
/// "x" row — by thirteen ranks. Replaces the two-tap rank→suit picker
/// everywhere cards are entered. Cards already in play are disabled; x cards
/// never are (two Kx can both be live — nobody knows the real suit, so there
/// is nothing to collide on).
struct CardGrid: View {
    let dealt: Set<PlayingCard>
    let onPick: (PlayingCard) -> Void

    private static let ranks: [Character] = ["A", "K", "Q", "J", "T", "9", "8", "7", "6", "5", "4", "3", "2"]
    private static let suits: [Character] = ["s", "h", "d", "c", "x"]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Self.suits, id: \.self) { suit in
                HStack(spacing: 3) {
                    Text(suitSymbol(suit))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(suitColor(suit))
                        .frame(width: 14)
                    ForEach(Self.ranks, id: \.self) { rank in
                        cell(rank: rank, suit: suit)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(rank: Character, suit: Character) -> some View {
        let card = PlayingCard(rank: rank, suit: suit)
        let isUnknown = suit == "x"
        let isDisabled = card == nil || (!isUnknown && dealt.contains(card!))
        Button {
            if let card { onPick(card) }
        } label: {
            Text(rank == "T" ? "10" : String(rank))
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(isUnknown ? Color.clear : Color.backgroundPrimary)
                .foregroundColor(suitColor(suit))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.textSecondary.opacity(isUnknown ? 0.5 : 0),
                                style: StrokeStyle(lineWidth: 1, dash: [3]))
                )
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .opacity(isDisabled ? 0.22 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel("\(rank == "T" ? "10" : String(rank)) of \(suitName(suit))")
    }

    private func suitSymbol(_ s: Character) -> String {
        switch s {
        case "s": return "♠"
        case "h": return "♥"
        case "d": return "♦"
        case "c": return "♣"
        default: return "x"
        }
    }

    private func suitName(_ s: Character) -> String {
        switch s {
        case "s": return "spades"
        case "h": return "hearts"
        case "d": return "diamonds"
        case "c": return "clubs"
        default: return "unknown suit"
        }
    }

    private func suitColor(_ s: Character) -> Color {
        switch s {
        case "h", "d": return .red
        case "x": return .textSecondary
        default: return .textPrimary
        }
    }
}

#Preview {
    CardGrid(dealt: Set(PlayingCard.parseList("Ah Kd Ks"))) { _ in }
        .padding()
        .background(Color.backgroundPrimary)
}
