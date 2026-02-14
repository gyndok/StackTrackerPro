import SwiftUI

struct CashSessionStatusBar: View {
    let session: CashSession

    var body: some View {
        HStack(spacing: 12) {
            // Left: session name + venue
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)

                if let venue = session.venueName, !venue.isEmpty {
                    Text(venue)
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Center: timer (live when active, fixed when completed)
            if session.status == .completed, let endTime = session.endTime {
                let elapsed = endTime.timeIntervalSince(session.startTime)
                let hours = Int(elapsed) / 3600
                let minutes = (Int(elapsed) % 3600) / 60
                let seconds = Int(elapsed) % 60

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .foregroundColor(.goldAccent)
                        .font(.caption)
                    Text(String(format: "%d:%02d:%02d", hours, minutes, seconds))
                        .font(PokerTypography.statValue)
                        .foregroundColor(.goldAccent)
                        .monospacedDigit()
                }
            } else {
                TimelineView(.periodic(from: .now, by: 1.0)) { context in
                    let elapsed = context.date.timeIntervalSince(session.startTime)
                    let hours = Int(elapsed) / 3600
                    let minutes = (Int(elapsed) % 3600) / 60
                    let seconds = Int(elapsed) % 60

                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .foregroundColor(.goldAccent)
                            .font(.caption)
                        Text(String(format: "%d:%02d:%02d", hours, minutes, seconds))
                            .font(PokerTypography.statValue)
                            .foregroundColor(.goldAccent)
                            .monospacedDigit()
                    }
                }
            }

            Spacer()

            // Right: current P/L
            if let latest = session.latestStack {
                let pl = latest.chipCount - session.buyInTotal
                Text(pl >= 0 ? "+$\(pl.formatted())" : "-$\(abs(pl).formatted())")
                    .font(PokerTypography.statValue)
                    .foregroundColor(pl >= 0 ? .mZoneGreen : .chipRed)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.backgroundSecondary)
    }
}

#Preview {
    CashSessionStatusBar(session: {
        let s = CashSession(stakes: "1/2", gameType: .nlh, buyInTotal: 300, venueName: "Bellagio")
        return s
    }())
    .background(Color.backgroundPrimary)
}
