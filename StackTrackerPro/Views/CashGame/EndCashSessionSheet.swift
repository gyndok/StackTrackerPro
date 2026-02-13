import SwiftUI

struct EndCashSessionSheet: View {
    @Environment(CashSessionManager.self) private var cashSessionManager
    @Environment(\.dismiss) private var dismiss

    let session: CashSession

    @State private var cashOutText = ""

    // MARK: - Computed

    private var parsedCashOut: Int? {
        Int(cashOutText)
    }

    private var computedProfit: Int? {
        guard let cashOut = parsedCashOut else { return nil }
        return cashOut - session.buyInTotal
    }

    private var elapsedInterval: TimeInterval {
        Date.now.timeIntervalSince(session.startTime)
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

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cashOutSection
                    sessionSummarySection
                    endButton
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("End Session")
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

    private var cashOutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CASH OUT")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)

            VStack(spacing: 0) {
                HStack {
                    Text("$")
                        .font(.title2.weight(.semibold))
                        .foregroundColor(.textSecondary)
                    TextField("0", text: $cashOutText)
                        .keyboardType(.numberPad)
                        .font(.title2.weight(.semibold))
                        .foregroundColor(.textPrimary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
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
                summaryRow("Stakes", value: session.displayName)

                Divider().background(Color.textSecondary.opacity(0.2))

                // Live duration
                TimelineView(.periodic(from: .now, by: 1.0)) { context in
                    let elapsed = context.date.timeIntervalSince(session.startTime)
                    let hours = Int(elapsed) / 3600
                    let minutes = (Int(elapsed) % 3600) / 60
                    let durationStr = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
                    summaryRow("Duration", value: durationStr)
                }

                Divider().background(Color.textSecondary.opacity(0.2))

                summaryRow("Total Buy-in", value: "$\(session.buyInTotal.formatted())")

                if let profit = computedProfit {
                    Divider().background(Color.textSecondary.opacity(0.2))
                    summaryRow(
                        "Profit / Loss",
                        value: profit >= 0 ? "+$\(profit.formatted())" : "-$\(abs(profit).formatted())",
                        valueColor: profit >= 0 ? .mZoneGreen : .chipRed
                    )
                }

                if let rate = computedHourlyRate {
                    Divider().background(Color.textSecondary.opacity(0.2))
                    let formatted = String(format: "$%.0f/hr", abs(rate))
                    summaryRow(
                        "Hourly Rate",
                        value: rate >= 0 ? "+\(formatted)" : "-\(formatted)",
                        valueColor: rate >= 0 ? .mZoneGreen : .chipRed
                    )
                }
            }
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var endButton: some View {
        Button {
            endSession()
        } label: {
            Text("End Session")
        }
        .buttonStyle(PokerButtonStyle(isEnabled: parsedCashOut != nil))
        .disabled(parsedCashOut == nil)
        .padding(.top, 8)
    }

    // MARK: - Row Helpers

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

    private func endSession() {
        guard let cashOut = parsedCashOut else { return }
        cashSessionManager.completeSession(cashOut: cashOut)
        HapticFeedback.success()
        dismiss()
    }
}

#Preview {
    EndCashSessionSheet(session: {
        let s = CashSession(stakes: "1/2", gameType: .nlh, buyInTotal: 300, venueName: "Bellagio")
        return s
    }())
    .environment(CashSessionManager())
}
