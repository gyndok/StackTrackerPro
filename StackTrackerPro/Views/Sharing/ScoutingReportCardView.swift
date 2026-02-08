import SwiftUI

struct ScoutingReportCardView: View {
    let tournament: Tournament
    let report: ScoutingReport
    let size: ShareCardSize

    private var isSquare: Bool { size == .square }

    var body: some View {
        ZStack {
            ShareCardBackground()

            VStack(spacing: isSquare ? 8 : 12) {
                ShareCardHeader(
                    eventName: tournament.name,
                    venueName: tournament.venueName
                )

                GoldDivider()

                // Speed badge
                Text(report.structureSpeed.rawValue.uppercased())
                    .font(.system(size: isSquare ? 22 : 28, weight: .bold, design: .rounded))
                    .foregroundColor(.backgroundPrimary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(report.structureSpeed.color)
                    )

                // Metrics row
                HStack(spacing: 0) {
                    metricColumn(label: "Starting BBs", value: "\(Int(report.startingBBs))")
                    metricColumn(
                        label: "Antes Start",
                        value: report.antesIntroducedLevel.map { "Lvl \($0)" } ?? "None"
                    )
                    metricColumn(
                        label: "Est. ITM",
                        value: report.estimatedITMPlayers > 0 ? "\(report.estimatedITMPlayers)" : "—"
                    )
                    metricColumn(
                        label: "Overlay",
                        value: report.overlayAmount > 0 ? "$\(report.overlayAmount.formatted())" : "$0"
                    )
                }

                GoldDivider()

                // Approach bullets
                VStack(alignment: .leading, spacing: isSquare ? 4 : 6) {
                    ForEach(report.approachBullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(Color.goldAccent)
                                .frame(width: 5, height: 5)
                                .padding(.top, 5)
                            Text(bullet)
                                .font(PokerTypography.shareLabel)
                                .foregroundColor(.textPrimary)
                                .lineLimit(2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                GoldDivider()

                ShareCardFooter()
            }
            .padding(16)
        }
    }

    private func metricColumn(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(PokerTypography.shareValue)
                .foregroundColor(.textPrimary)
            Text(label)
                .font(PokerTypography.shareLabel)
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}
