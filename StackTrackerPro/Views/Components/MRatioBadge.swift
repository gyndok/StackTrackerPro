import SwiftUI

struct MRatioBadge: View {
    let mRatio: Double

    private var zone: MZone {
        MZone.from(mRatio: mRatio)
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(zone.color)
                .frame(width: 8, height: 8)
            Text(String(format: "M: %.0f", mRatio))
                .font(PokerTypography.chipLabel)
                .foregroundColor(zone.color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(zone.color.opacity(0.15))
        .clipShape(Capsule())
    }
}

#Preview {
    VStack(spacing: 12) {
        MRatioBadge(mRatio: 25)
        MRatioBadge(mRatio: 15)
        MRatioBadge(mRatio: 7)
        MRatioBadge(mRatio: 3)
    }
    .padding()
    .background(Color.backgroundPrimary)
}
