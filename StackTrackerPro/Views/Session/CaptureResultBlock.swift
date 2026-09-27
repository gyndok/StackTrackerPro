import SwiftUI

/// Result-row tap rules (spec §4), pure so they are unit-tested.
enum ResultRowLogic {
    /// Tapping the set the engine already computed means "trust computed"
    /// (clear the override); anything else — including any tap when no
    /// winner could be computed — is an explicit ruling.
    static func overrideAfterTap(_ tapped: Set<HandCaptureModel.Participant>,
                                 computed: [HandCaptureModel.Participant]) -> Set<HandCaptureModel.Participant>? {
        !computed.isEmpty && Set(computed) == tapped ? nil : tapped
    }

    /// The loud banner is for a REAL disagreement between entered cards and
    /// the tapped result — an override with no cards is the normal path.
    static func showsMismatchBanner(override: Set<HandCaptureModel.Participant>?,
                                    computed: [HandCaptureModel.Participant]) -> Bool {
        guard let override, !computed.isEmpty else { return false }
        return Set(computed) != override
    }
}

/// Result block for a finished hand (spec §4): at a showdown the result
/// buttons come first and Save lights up on the first tap; shown cards are
/// an optional disclosure beneath. Fold-outs show only the result line.
struct ResultBlock: View {
    let model: HandCaptureModel

    @State private var showCards = false

    private var candidates: [HandCaptureModel.Participant] {
        ([.hero] + model.villains.map { .villain($0.id) })
            .filter { !model.foldedParticipants.contains($0) }
    }

    private var selected: Set<HandCaptureModel.Participant> {
        model.winnerOverride ?? Set(model.computedWinners)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Result").font(PokerTypography.sectionHeader).foregroundColor(.goldAccent)

            if model.needsShowdown {
                resultRow
                if ResultRowLogic.showsMismatchBanner(override: model.winnerOverride,
                                                      computed: model.computedWinners) {
                    HStack(spacing: 8) {
                        Label("Cards say \(describe(Set(model.computedWinners))) — result overridden",
                              systemImage: "flag.fill")
                            .font(PokerTypography.chipLabel)
                            .foregroundColor(.chipRed)
                        Spacer()
                        Button("Use cards") { model.winnerOverride = nil }
                            .font(.caption)
                            .foregroundColor(.goldAccent)
                    }
                }
                DisclosureGroup(isExpanded: $showCards) {
                    ForEach(model.villains.filter { !model.foldedParticipants.contains(.villain($0.id)) }) { villain in
                        VillainShowdownRow(model: model, villain: villain)
                    }
                } label: {
                    Text("Add shown cards")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)
                }
                .tint(.goldAccent)
            }

            Text(resultLine)
                .font(PokerTypography.statValue)
                .foregroundColor(model.heroNet >= 0 ? .mZoneGreen : .chipRed)
        }
        .pokerCard()
    }

    private var resultRow: some View {
        HStack(spacing: 8) {
            ForEach(candidates, id: \.self) { participant in
                resultButton(title: participant == .hero ? "Hero won" : "\(model.label(for: participant)) won",
                             set: [participant])
            }
            if candidates.count > 1 {
                resultButton(title: "Chop", set: Set(candidates))
            }
        }
    }

    private func resultButton(title: String, set: Set<HandCaptureModel.Participant>) -> some View {
        let isOn = selected == set
        return Button {
            model.winnerOverride = ResultRowLogic.overrideAfterTap(set, computed: model.computedWinners)
            HapticFeedback.impact(.medium)
        } label: {
            Text(title)
                .font(PokerTypography.chipLabel.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(isOn ? Color.goldAccent : Color.backgroundPrimary)
                .foregroundColor(isOn ? .backgroundPrimary : .textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func describe(_ set: Set<HandCaptureModel.Participant>) -> String {
        set.map { model.label(for: $0) }.sorted().joined(separator: ", ")
    }

    private var resultLine: String {
        if model.needsShowdown, model.effectiveWinners.isEmpty {
            return "Tap who won, or add shown cards."
        }
        let net = model.heroNet
        let verb = net >= 0 ? "wins" : "loses"
        return "Hero \(verb) \(abs(net).formatted())"
    }
}

/// A villain's showdown resolution is either already known (shown holding or
/// mucked) or not — the card picker appears automatically while unresolved,
/// with no separate "reveal" tap; resolved rows collapse to a read-only
/// summary with a lightweight "Edit" affordance to reopen it.
private struct VillainShowdownRow: View {
    let model: HandCaptureModel
    let villain: HandCaptureModel.VillainDraft

    @State private var forceEditing = false

    private var isResolved: Bool { villain.shownHolding.count == 2 || villain.mucked }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.label(for: .villain(villain.id)))
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(.textPrimary)
                Spacer()
                if villain.shownHolding.count == 2 {
                    Text(villain.shownHolding.map(\.display).joined(separator: " "))
                        .font(PokerTypography.statValue)
                        .foregroundColor(.textPrimary)
                }
                if villain.mucked {
                    Text("Mucked").font(PokerTypography.chipLabel).foregroundColor(.textSecondary)
                }
                if isResolved {
                    Button("Edit") { forceEditing = true }
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                } else {
                    Button("Mucked") { model.setMucked(villain.id) }
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                }
            }
            if !isResolved || forceEditing {
                CardGrid(dealt: model.dealtCards) { card in
                    var cards = villain.shownHolding
                    guard cards.count < 2 else { return }
                    cards.append(card)
                    model.setShownHolding(cards, for: villain.id)
                    if cards.count == 2 { forceEditing = false }
                }
            }
        }
    }
}
