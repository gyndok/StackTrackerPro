import SwiftUI

struct CashSessionRecapSheet: View {
    let session: CashSession
    let onDismiss: () -> Void

    // MARK: - Computed

    private var profit: Int {
        (session.cashOut ?? 0) - session.buyInTotal
    }

    private var formattedDuration: String {
        guard let dur = session.duration else { return "---" }
        let hours = Int(dur) / 3600
        let minutes = (Int(dur) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private var formattedHourlyRate: String {
        guard let rate = session.hourlyRate else { return "---" }
        let formatted = String(format: "$%.0f/hr", abs(rate))
        return rate >= 0 ? "+\(formatted)" : "-\(formatted)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Hero P/L
                    VStack(spacing: 4) {
                        Text("Profit / Loss")
                            .font(PokerTypography.chipLabel)
                            .foregroundColor(.textSecondary)

                        Text(profit >= 0 ? "+$\(profit.formatted())" : "-$\(abs(profit).formatted())")
                            .font(PokerTypography.heroStat)
                            .foregroundColor(profit >= 0 ? .mZoneGreen : .chipRed)
                    }
                    .frame(maxWidth: .infinity)
                    .pokerCard()

                    // Session info
                    VStack(spacing: 4) {
                        Text(session.displayName)
                            .font(.headline)
                            .foregroundColor(.textPrimary)

                        if let venue = session.venueName, !venue.isEmpty {
                            Text(venue)
                                .font(PokerTypography.chatCaption)
                                .foregroundColor(.textSecondary)
                        }
                    }

                    // Stat rows
                    VStack(spacing: 0) {
                        statRow("Duration", value: formattedDuration)

                        Divider().background(Color.textSecondary.opacity(0.2))

                        statRow("Buy-in", value: "$\(session.buyInTotal.formatted())")

                        Divider().background(Color.textSecondary.opacity(0.2))

                        statRow("Cash Out", value: "$\((session.cashOut ?? 0).formatted())")

                        Divider().background(Color.textSecondary.opacity(0.2))

                        statRow(
                            "Hourly Rate",
                            value: formattedHourlyRate,
                            valueColor: session.hourlyRate.map { $0 >= 0 ? .mZoneGreen : .chipRed } ?? .textPrimary
                        )
                    }
                    .background(Color.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Done button
                    Button {
                        onDismiss()
                    } label: {
                        Text("Done")
                    }
                    .buttonStyle(PokerButtonStyle(isEnabled: true))
                    .padding(.top, 8)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Session Recap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onDismiss()
                    }
                    .foregroundColor(.goldAccent)
                }
            }
        }
    }

    // MARK: - Row Helper

    private func statRow(_ label: String, value: String, valueColor: Color = .textPrimary) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.textSecondary)
            Spacer()
            Text(value)
                .foregroundColor(valueColor)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

#Preview {
    CashSessionRecapSheet(session: {
        let s = CashSession(stakes: "1/2", gameType: .nlh, buyInTotal: 300, venueName: "Bellagio")
        s.cashOut = 550
        s.endTime = Date.now
        return s
    }(), onDismiss: {})
}
