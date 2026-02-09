import SwiftUI

struct StatusBarView: View {
    let tournament: Tournament
    @Environment(TournamentManager.self) private var tournamentManager
    @AppStorage(SettingsKeys.showMRatio) private var showMRatio = false

    var body: some View {
        HStack(spacing: 12) {
            // Tournament name + game type
            VStack(alignment: .leading, spacing: 2) {
                Text(tournament.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)

                Text(tournament.gameType.label)
                    .font(PokerTypography.chatCaption)
                    .foregroundColor(.textSecondary)
            }

            Spacer()

            // Break countdown or blind level
            if tournamentManager.isOnBreak, let endTime = tournamentManager.breakEndTime {
                TimelineView(.periodic(from: .now, by: 1.0)) { context in
                    let remaining = max(0, endTime.timeIntervalSince(context.date))
                    let minutes = Int(remaining) / 60
                    let seconds = Int(remaining) % 60
                    HStack(spacing: 4) {
                        Image(systemName: "cup.and.saucer.fill")
                            .foregroundColor(remaining <= 120 ? .mZoneRed : .goldAccent)
                        Text(String(format: "%d:%02d", minutes, seconds))
                            .font(PokerTypography.statValue)
                            .foregroundColor(remaining <= 120 ? .mZoneRed : .goldAccent)
                            .monospacedDigit()
                    }
                }
            } else if let blinds = tournament.currentBlinds, !blinds.isBreak {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Level \(tournament.currentDisplayLevel ?? blinds.levelNumber)")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.goldAccent)

                    Text(blinds.blindsDisplay)
                        .font(PokerTypography.blindLevel)
                        .foregroundColor(.textPrimary)
                }
            }

            // BB badge
            if let latest = tournament.latestStack, latest.bbCount > 0 {
                BBBadge(bbCount: latest.bbCount)
            }

            // M-ratio badge
            if showMRatio, let latest = tournament.latestStack, latest.mRatio > 0 {
                MRatioBadge(mRatio: latest.mRatio)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.backgroundSecondary)
    }
}

#Preview {
    StatusBarView(tournament: {
        let t = Tournament(name: "Friday $150 NLH", gameType: .nlh, startingChips: 20000)
        return t
    }())
}
