import SwiftUI

struct ScoutingReportView: View {
    let tournament: Tournament
    @State private var showShareSheet = false
    @State private var renderedImage: UIImage?

    private var report: ScoutingReport {
        ScoutingReportEngine.generate(for: tournament)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection
                keyMetricsGrid
                criticalLevelsSection

                if report.hasBounty {
                    bountySection
                }

                gameStrategySection
                approachSection
                shareButton
            }
            .padding(16)
        }
        .background(Color.backgroundPrimary)
        .navigationTitle("Scouting Report")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShareSheet) {
            ScoutingReportShareSheet(tournament: tournament, report: report)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Text("SCOUTING REPORT")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)

            Spacer()

            Text(report.structureSpeed.rawValue.uppercased())
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.backgroundPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(report.structureSpeed.color)
                )
        }
    }

    // MARK: - Key Metrics

    private var keyMetricsGrid: some View {
        let bbColor: Color = {
            if report.startingBBs >= 30 { return .mZoneGreen }
            else if report.startingBBs >= 15 { return .mZoneYellow }
            else if report.startingBBs >= 8 { return .mZoneOrange }
            else { return .mZoneRed }
        }()

        let antesText = report.antesIntroducedLevel.map { "Level \($0)" } ?? "None"

        let itmText = report.estimatedITMPlayers > 0
            ? "\(report.estimatedITMPlayers) players"
            : "—"

        let overlayText = report.overlayAmount > 0
            ? "$\(report.overlayAmount.formatted())"
            : "$0"
        let overlayColor: Color = report.overlayAmount > 0 ? .mZoneGreen : .textPrimary

        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                StatBlockView(label: "Starting BBs", value: "\(Int(report.startingBBs))", valueColor: bbColor)
                StatBlockView(label: "Antes Start", value: antesText)
            }
            HStack(spacing: 8) {
                StatBlockView(label: "Est. ITM", value: itmText)
                StatBlockView(label: "Overlay", value: overlayText, valueColor: overlayColor)
            }
        }
    }

    // MARK: - Critical Levels

    private var criticalLevelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CRITICAL LEVELS")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)

            if report.criticalLevels.isEmpty {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.textSecondary)
                    Text("Import blind structure for detailed analysis")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 6) {
                    ForEach(report.criticalLevels, id: \.levelNumber) { level in
                        criticalLevelRow(level)
                    }
                }
            }
        }
    }

    private func criticalLevelRow(_ level: CriticalLevel) -> some View {
        HStack(spacing: 12) {
            // Level badge
            ZStack {
                Circle()
                    .fill(level.zoneColor.opacity(0.2))
                    .frame(width: 36, height: 36)
                Text("\(level.levelNumber)")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(level.zoneColor)
            }

            // Blinds display
            VStack(alignment: .leading, spacing: 2) {
                Text(level.blindsDisplay)
                    .font(PokerTypography.blindLevel)
                    .foregroundColor(.textPrimary)
                Text("\(Int(level.bbCount)) BBs")
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(.textSecondary)
            }

            Spacer()

            // Zone badge
            Text(level.zone)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(level.zoneColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(level.zoneColor.opacity(0.15))
                )
        }
        .padding(12)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Bounty Analysis

    private var bountySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BOUNTY ANALYSIS")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Bounty")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)
                    Spacer()
                    Text("$\(tournament.bountyAmount)")
                        .font(PokerTypography.statValue)
                        .foregroundColor(.goldAccent)
                }

                if let pct = report.bountyPercentOfBuyIn {
                    HStack {
                        Text("% of Buy-in")
                            .font(PokerTypography.chipLabel)
                            .foregroundColor(.textSecondary)
                        Spacer()
                        Text("\(Int(pct))%")
                            .font(PokerTypography.statValue)
                            .foregroundColor(.textPrimary)
                    }
                }

                GoldDivider()

                Text("Adjust calling ranges wider when covering short stacks — bounty equity adds value to marginal spots.")
                    .font(PokerTypography.chatBody)
                    .foregroundColor(.textSecondary)
            }
            .padding(12)
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Game Strategy

    private var gameStrategySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GAME STRATEGY")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(report.gameTypeNotes, id: \.self) { note in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Color.goldAccent)
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                        Text(note)
                            .font(PokerTypography.chatBody)
                            .foregroundColor(.textPrimary)
                    }
                }
            }
            .padding(12)
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Recommended Approach

    private var approachSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("YOUR APPROACH")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(report.approachBullets.enumerated()), id: \.offset) { index, bullet in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.goldAccent)
                            .frame(width: 20, alignment: .trailing)
                        Text(bullet)
                            .font(PokerTypography.chatBody)
                            .foregroundColor(.textPrimary)
                    }
                }
            }
            .padding(12)
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.goldAccent.opacity(0.3), lineWidth: 1)
            )
        }
    }

    // MARK: - Share Button

    private var shareButton: some View {
        Button {
            showShareSheet = true
        } label: {
            HStack {
                Image(systemName: "square.and.arrow.up")
                Text("Share Scouting Report")
            }
            .font(.headline.weight(.semibold))
            .foregroundColor(.backgroundPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.goldAccent)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Scouting Report Share Sheet

struct ScoutingReportShareSheet: View {
    let tournament: Tournament
    let report: ScoutingReport
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSize: ShareCardSize = .stories
    @State private var renderedImage: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Size", selection: $selectedSize) {
                        ForEach(ShareCardSize.allCases, id: \.self) { size in
                            Text(size.rawValue).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    if let image = renderedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                            .padding(.horizontal, 24)
                    } else {
                        ProgressView()
                            .frame(height: 300)
                    }

                    if let uiImage = renderedImage {
                        let shareImage = ShareableImage(
                            image: Image(uiImage: uiImage),
                            uiImage: uiImage
                        )
                        ShareLink(
                            item: shareImage,
                            preview: SharePreview(
                                tournament.name,
                                image: Image(uiImage: uiImage)
                            )
                        ) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("Share")
                            }
                            .font(.headline.weight(.semibold))
                            .foregroundColor(.backgroundPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.goldAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.horizontal, 24)
                    }
                }
                .padding(.vertical, 16)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Share Scouting Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.goldAccent)
                }
            }
        }
        .onAppear { renderCard() }
        .onChange(of: selectedSize) { _, _ in renderCard() }
    }

    private func renderCard() {
        let card = ScoutingReportCardView(tournament: tournament, report: report, size: selectedSize)
        renderedImage = ShareCardRenderer.render(card, size: selectedSize)
    }
}
