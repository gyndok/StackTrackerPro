import SwiftUI

struct StatBlockView: View {
    let label: String
    let value: String
    var trend: TrendDirection?
    var valueColor: Color = .textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(PokerTypography.chipLabel)
                .foregroundColor(.textSecondary)

            HStack(spacing: 4) {
                Text(value)
                    .font(PokerTypography.statValue)
                    .foregroundColor(valueColor)

                if let trend {
                    Image(systemName: trend.icon)
                        .font(.caption2)
                        .foregroundColor(trend.color)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

enum TrendDirection {
    case up, down, flat

    var icon: String {
        switch self {
        case .up: return "arrow.up.right"
        case .down: return "arrow.down.right"
        case .flat: return "arrow.right"
        }
    }

    var color: Color {
        switch self {
        case .up: return .mZoneGreen
        case .down: return .mZoneRed
        case .flat: return .textSecondary
        }
    }
}

#Preview {
    HStack {
        StatBlockView(label: "Stack", value: "18k", trend: .down, valueColor: .mZoneYellow)
        StatBlockView(label: "BB", value: "45", trend: .up)
    }
    .padding()
    .background(Color.backgroundPrimary)
}
