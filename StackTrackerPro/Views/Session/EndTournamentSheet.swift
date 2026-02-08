import SwiftUI

struct EndTournamentSheet: View {
    @Environment(TournamentManager.self) private var tournamentManager
    @Environment(\.dismiss) private var dismiss

    let tournament: Tournament

    @State private var finishPositionText = ""
    @State private var payoutText = ""

    // MARK: - Computed

    private var parsedPayout: Int? {
        Int(payoutText)
    }

    private var computedProfit: Int? {
        guard let payout = parsedPayout else { return nil }
        return payout + (tournament.bountiesCollected * tournament.bountyAmount) - tournament.totalInvestment
    }

    private var elapsedInterval: TimeInterval {
        Date.now.timeIntervalSince(tournament.startDate)
    }

    private var liveDuration: String {
        let elapsed = elapsedInterval
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private var computedHourlyRate: Double? {
        guard let profit = computedProfit, elapsedInterval > 0 else { return nil }
        let hours = elapsedInterval / 3600
        return Double(profit) / hours
    }

    private var peakStack: Int {
        tournament.sortedStackEntries.map(\.chipCount).max() ?? tournament.startingChips
    }

    private var bountyTotal: Int {
        tournament.bountiesCollected * tournament.bountyAmount
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    finishDetailsSection
                    sessionSummarySection
                    endButton
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("End Tournament")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
            }
        }
    }

    // MARK: - Sections

    private var finishDetailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FINISH DETAILS")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)

            VStack(spacing: 0) {
                numberRow("Finish Position", text: $finishPositionText, placeholder: "e.g. 5")

                Divider()
                    .background(Color.textSecondary.opacity(0.2))

                currencyRow("Payout", text: $payoutText, placeholder: "0")
            }
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var sessionSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SESSION SUMMARY")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)

            VStack(spacing: 0) {
                summaryRow("Duration", value: liveDuration)

                Divider().background(Color.textSecondary.opacity(0.2))

                summaryRow("Total Investment", value: "$\(tournament.totalInvestment.formatted())")

                if tournament.bountiesCollected > 0 && tournament.bountyAmount > 0 {
                    Divider().background(Color.textSecondary.opacity(0.2))
                    summaryRow(
                        "Bounties Earned",
                        value: "\(tournament.bountiesCollected) × $\(tournament.bountyAmount.formatted()) = $\(bountyTotal.formatted())"
                    )
                }

                if let profit = computedProfit {
                    Divider().background(Color.textSecondary.opacity(0.2))
                    summaryRow(
                        "Profit / Loss",
                        value: profit >= 0 ? "+$\(profit.formatted())" : "-$\(abs(profit).formatted())",
                        valueColor: profit >= 0 ? .green : .red
                    )
                }

                if let rate = computedHourlyRate {
                    Divider().background(Color.textSecondary.opacity(0.2))
                    let formatted = String(format: "$%.0f/hr", abs(rate))
                    summaryRow(
                        "Hourly Rate",
                        value: rate >= 0 ? "+\(formatted)" : "-\(formatted)",
                        valueColor: rate >= 0 ? .green : .red
                    )
                }

                Divider().background(Color.textSecondary.opacity(0.2))

                summaryRow("Peak Stack", value: formatChips(peakStack))

                if tournament.fieldSize > 0 {
                    Divider().background(Color.textSecondary.opacity(0.2))
                    summaryRow("Field Size", value: "\(tournament.fieldSize)")
                }
            }
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var endButton: some View {
        Button {
            endTournament()
        } label: {
            Text("End Tournament")
                .font(.headline.weight(.semibold))
                .foregroundColor(.backgroundPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.goldAccent)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.top, 8)
    }

    // MARK: - Row Helpers

    private func numberRow(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.textSecondary)
            Spacer()
            TextField(placeholder, text: text)
                .keyboardType(.numberPad)
                .foregroundColor(.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func currencyRow(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.textSecondary)
            Spacer()
            HStack(spacing: 2) {
                Text("$")
                    .foregroundColor(.textSecondary)
                TextField(placeholder, text: text)
                    .keyboardType(.numberPad)
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func summaryRow(_ label: String, value: String, valueColor: Color = .textPrimary) -> some View {
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

    // MARK: - Actions

    private func endTournament() {
        let position = Int(finishPositionText)
        let payout = parsedPayout
        tournamentManager.completeTournament(position: position, payout: payout, endDate: .now)
        dismiss()
    }

    // MARK: - Formatting

    private func formatChips(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        } else if value >= 1000 {
            return String(format: "%.0fk", Double(value) / 1000)
        }
        return "\(value)"
    }
}
