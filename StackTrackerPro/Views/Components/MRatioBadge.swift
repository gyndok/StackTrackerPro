import SwiftUI

struct BBBadge: View {
    let bbCount: Double
    @State private var previousZone: BBZone?

    private var zone: BBZone {
        BBZone.from(bbCount: bbCount)
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(zone.color)
                .frame(width: 8, height: 8)
            Text(String(format: "BB: %.1f", bbCount))
                .font(PokerTypography.chipLabel)
                .foregroundColor(zone.color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(zone.color.opacity(0.15))
        .clipShape(Capsule())
        .onChange(of: zone) { oldZone, newZone in
            guard previousZone != nil else {
                previousZone = newZone
                return
            }
            if oldZone != newZone {
                HapticFeedback.notification(newZone.isWorseThan(oldZone) ? .warning : .success)
                previousZone = newZone
            }
        }
        .onAppear {
            previousZone = zone
        }
    }
}

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
            Text(String(format: "M: %.1f", mRatio))
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
        BBBadge(bbCount: 34.0)
        BBBadge(bbCount: 20.0)
        BBBadge(bbCount: 10.0)
        BBBadge(bbCount: 5.0)
    }
    .padding()
    .background(Color.backgroundPrimary)
}
