import SwiftUI
import SwiftData

struct EditResultSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Bindable var tournament: Tournament

    @State private var finishPositionText: String = ""
    @State private var payoutText: String = ""

    // MARK: - Computed

    private var parsedPayout: Int? {
        Int(payoutText)
    }

    private var computedProfit: Int? {
        guard let payout = parsedPayout else { return nil }
        return payout + (tournament.bountiesCollected * tournament.bountyAmount) - tournament.totalInvestment
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    editSection
                    summarySection
                    saveButton
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Edit Result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
            }
        }
        .onAppear {
            if let pos = tournament.finishPosition {
                finishPositionText = "\(pos)"
            }
            if let payout = tournament.payout {
                payoutText = "\(payout)"
            }
        }
    }

    // MARK: - Sections

    private var editSection: some View {
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

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("UPDATED SUMMARY")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)

            VStack(spacing: 0) {
                summaryRow("Total Investment", value: "$\(tournament.totalInvestment.formatted())")

                if tournament.bountiesCollected > 0 && tournament.bountyAmount > 0 {
                    Divider().background(Color.textSecondary.opacity(0.2))
                    let bountyTotal = tournament.bountiesCollected * tournament.bountyAmount
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
            }
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var saveButton: some View {
        Button {
            saveChanges()
        } label: {
            Text("Save Changes")
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

    private func saveChanges() {
        tournament.finishPosition = Int(finishPositionText)
        tournament.payout = parsedPayout ?? 0
        try? modelContext.save()
        dismiss()
    }
}
