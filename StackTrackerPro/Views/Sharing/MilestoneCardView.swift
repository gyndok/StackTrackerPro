import SwiftUI

struct MilestoneCardView: View {
    let milestone: MilestoneType
    let detail: String
    let size: ShareCardSize

    var body: some View {
        ZStack {
            ShareCardBackground()

            VStack(spacing: 20) {
                Spacer()

                // Large icon
                Image(systemName: milestone.icon)
                    .font(.system(size: 56))
                    .foregroundColor(.goldAccent)

                // Caption
                Text("MILESTONE")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(3)
                    .foregroundColor(.textSecondary)

                // Title
                Text(milestone.title)
                    .font(PokerTypography.shareHero)
                    .foregroundColor(.goldAccent)
                    .multilineTextAlignment(.center)

                // Detail
                Text(detail)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.center)

                GoldDivider()
                    .padding(.horizontal, 40)

                ShareCardFooter()

                Spacer()
            }
            .padding(16)
        }
    }
}
