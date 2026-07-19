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

                Text(tournament.gameTypeLabel)
                    .font(PokerTypography.chatCaption)
                    .foregroundColor(.textSecondary)
            }

            Spacer()

            // Players-remaining stepper (active sessions only — nothing to
            // step once the field has never been seeded or the tournament
            // is paused/completed).
            if tournament.status == .active && tournament.playersRemaining > 0 {
                HStack(spacing: 6) {
                    stepButton("minus.circle.fill", accessibilityLabel: "Decrement players remaining") {
                        tournamentManager.stepPlayersRemaining(-1)
                    }

                    VStack(spacing: 0) {
                        Text("\(tournament.playersRemaining)")
                            .font(PokerTypography.statValue)
                            .monospacedDigit()
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)
                            .fixedSize()
                        Text("left")
                            .font(PokerTypography.chatCaption)
                            .foregroundColor(.textSecondary)
                            .lineLimit(1)
                            .fixedSize()
                    }

                    stepButton("plus.circle.fill", accessibilityLabel: "Increment players remaining") {
                        tournamentManager.stepPlayersRemaining(1)
                    }
                }
            }

            // Break countdown or blind level
            if tournamentManager.isOnBreak, let endTime = tournamentManager.breakEndTime {
                TimelineView(.periodic(from: .now, by: 1.0)) { context in
                    let remaining = max(0, endTime.timeIntervalSince(context.date))
                    let minutes = Int(remaining) / 60
                    let seconds = Int(remaining) % 60
                    HStack(spacing: 4) {
                        Image(systemName: "cup.and.saucer.fill")
                            .foregroundColor(remaining <= 120 ? .mZoneRed : .goldAccent)
                            .accessibilityHidden(true)
                        Text(String(format: "%d:%02d", minutes, seconds))
                            .font(PokerTypography.statValue)
                            .foregroundColor(remaining <= 120 ? .mZoneRed : .goldAccent)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Break time remaining")
                    .accessibilityValue("\(minutes) minutes \(seconds) seconds\(remaining <= 120 ? ", ending soon" : "")")
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

    /// A 44×44 tappable stepper control showing a 20pt SF Symbol, sized
    /// compactly so it doesn't blow out the status bar's height.
    @ViewBuilder
    private func stepButton(_ systemName: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button {
            HapticFeedback.impact(.light)
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 20))
                .foregroundColor(.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 24, height: 24)
        .accessibilityLabel(accessibilityLabel)
    }
}

#Preview {
    StatusBarView(tournament: {
        let t = Tournament(name: "Friday $150 NLH", gameType: .nlh, startingChips: 20000)
        return t
    }())
}
