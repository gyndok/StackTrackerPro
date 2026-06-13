import SwiftUI
import Charts

struct VideoRecapView: View {
    let tournament: Tournament
    let progress: Double

    // MARK: - Timing (matches VideoComposer)

    private var levelCount: Int {
        latestPerLevel.count
    }

    private var totalDuration: Double {
        1.5 + (Double(max(levelCount, 1)) * 0.5) + 2.0
    }

    /// Map progress (0–1) to seconds elapsed
    private var elapsed: Double {
        progress * totalDuration
    }

    // Act boundaries in seconds
    private var titleEnd: Double { 1.5 }
    private var graphEnd: Double { 1.5 + Double(max(levelCount, 1)) * 0.5 }

    // MARK: - Data

    private var latestPerLevel: [StackEntry] {
        let entries = tournament.sortedStackEntries
        let grouped = Dictionary(grouping: entries) { $0.blindLevelNumber }
        return grouped.compactMap { (_, group) in
            group.max(by: { $0.timestamp < $1.timestamp })
        }
        .sorted { $0.blindLevelNumber < $1.blindLevelNumber }
    }

    private var sortedPhotos: [ChipStackPhoto] {
        (tournament.chipStackPhotos ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    private var chipRange: ClosedRange<Int> {
        let chips = latestPerLevel.map(\.chipCount)
        let minVal = max(0, (chips.min() ?? 0) - 1000)
        let maxVal = (chips.max() ?? tournament.startingChips) + 1000
        return minVal...max(minVal + 1, maxVal)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            ShareCardBackground()

            if elapsed < titleEnd {
                titleCard
                    .opacity(titleOpacity)
            } else if elapsed < graphEnd {
                graphCard
            } else {
                recapCard
                    .opacity(recapOpacity)
            }
        }
    }

    // MARK: - Title Card

    private var titleOpacity: Double {
        let fadeIn = min(elapsed / 0.5, 1.0)
        let remaining = titleEnd - elapsed
        let fadeOut = remaining < 0.3 ? remaining / 0.3 : 1.0
        return fadeIn * fadeOut
    }

    private var titleCard: some View {
        VStack(spacing: 12) {
            Spacer()

            Text(tournament.name)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            if let venue = tournament.venueName, !venue.isEmpty {
                Text(venue)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.textSecondary)
            }

            if let date = tournament.endDate ?? Optional(tournament.startDate) {
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.textSecondary.opacity(0.7))
            }

            Spacer()

            AppWatermark(compact: false)
                .padding(.bottom, 20)
        }
        .padding(20)
    }

    // MARK: - Graph Card

    private var visibleLevelCount: Int {
        let graphElapsed = elapsed - titleEnd
        let levelsToShow = Int(graphElapsed / 0.5) + 1
        return min(levelsToShow, levelCount)
    }

    private var activePhoto: ChipStackPhoto? {
        let graphElapsed = elapsed - titleEnd
        let currentLevelIndex = min(Int(graphElapsed / 0.5), levelCount - 1)
        guard currentLevelIndex >= 0, currentLevelIndex < latestPerLevel.count else { return nil }
        let currentLevel = latestPerLevel[currentLevelIndex]

        let levelStartTime = Double(currentLevelIndex) * 0.5
        let timeSinceLevelStart = graphElapsed - levelStartTime
        guard timeSinceLevelStart >= 0, timeSinceLevelStart < 1.0 else { return nil }

        return sortedPhotos.first { $0.blindLevel == (tournament.displayLevelNumbers[currentLevel.blindLevelNumber] ?? currentLevel.blindLevelNumber) }
    }

    private var photoOpacity: Double {
        let graphElapsed = elapsed - titleEnd
        let currentLevelIndex = min(Int(graphElapsed / 0.5), levelCount - 1)
        let levelStartTime = Double(currentLevelIndex) * 0.5
        let timeSinceLevelStart = graphElapsed - levelStartTime

        let fadeIn = min(timeSinceLevelStart / 0.15, 1.0)
        let remaining = 1.0 - timeSinceLevelStart
        let fadeOut = remaining < 0.2 ? remaining / 0.2 : 1.0
        return fadeIn * fadeOut
    }

    private var graphCard: some View {
        let visibleData = Array(latestPerLevel.prefix(visibleLevelCount))

        return VStack(spacing: 12) {
            ShareCardHeader(
                eventName: tournament.name,
                venueName: tournament.venueName
            )

            GoldDivider()

            ZStack(alignment: .topTrailing) {
                Chart {
                    ForEach(Array(visibleData.enumerated()), id: \.offset) { index, entry in
                        AreaMark(
                            x: .value("Index", index),
                            y: .value("Chips", entry.chipCount)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.goldAccent.opacity(0.3), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)
                    }

                    ForEach(Array(visibleData.enumerated()), id: \.offset) { index, entry in
                        LineMark(
                            x: .value("Index", index),
                            y: .value("Chips", entry.chipCount)
                        )
                        .foregroundStyle(Color.goldAccent)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .interpolationMethod(.catmullRom)

                        PointMark(
                            x: .value("Index", index),
                            y: .value("Chips", entry.chipCount)
                        )
                        .foregroundStyle(entry.mZone.color)
                        .symbolSize(40)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisValueLabel {
                            if let chips = value.as(Int.self) {
                                Text(formatChipsShort(chips))
                                    .font(.caption2)
                                    .foregroundColor(.textSecondary)
                            }
                        }
                    }
                }
                .chartXScale(domain: 0...max(levelCount - 1, 1))
                .chartYScale(domain: chipRange)
                .frame(height: 350)

                if let photo = activePhoto, let uiImage = UIImage(data: photo.imageData) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 100, height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.6), radius: 8, y: 4)

                        Text("Lvl \(photo.blindLevel)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .padding(8)
                    .opacity(photoOpacity)
                }
            }

            GoldDivider()

            if visibleLevelCount > 0, visibleLevelCount <= latestPerLevel.count {
                let currentEntry = latestPerLevel[visibleLevelCount - 1]
                let displayLevel = tournament.displayLevelNumbers[currentEntry.blindLevelNumber] ?? currentEntry.blindLevelNumber
                HStack {
                    Text("Level \(displayLevel)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.goldAccent)
                    Spacer()
                    Text(currentEntry.formattedChipCount)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.textPrimary)
                }
            }

            Spacer()

            AppWatermark(compact: false)
        }
        .padding(16)
    }

    // MARK: - Recap Card

    private var recapOpacity: Double {
        let recapElapsed = elapsed - graphEnd
        return min(recapElapsed / 0.4, 1.0)
    }

    private var recapCard: some View {
        VStack(spacing: 14) {
            ShareCardHeader(
                eventName: tournament.name,
                venueName: tournament.venueName
            )

            GoldDivider()

            VStack(spacing: 4) {
                Text(positionText)
                    .font(PokerTypography.shareHero)
                    .foregroundColor(.goldAccent)

                Text(payoutText)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.textPrimary)
            }

            HStack(spacing: 0) {
                metricColumn(label: "Buy-in", value: "$\(tournament.totalInvestment.formatted())")
                metricColumn(label: "ROI", value: roiText)
                metricColumn(label: "Duration", value: tournament.durationFormatted)
                metricColumn(label: "Peak", value: formatChipsShort(peakStack))
            }

            GoldDivider()

            MiniStackChartView(
                entries: tournament.sortedStackEntries,
                height: 120
            )

            GoldDivider()

            ShareCardFooter()
        }
        .padding(16)
    }

    // MARK: - Recap Helpers

    private var positionText: String {
        guard let pos = tournament.finishPosition else { return "Completed" }
        let suffix: String
        let ones = pos % 10
        let tens = (pos / 10) % 10
        if tens == 1 { suffix = "th" }
        else {
            switch ones {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(pos)\(suffix) Place"
    }

    private var payoutText: String {
        guard let p = tournament.payout, p > 0 else { return "$0" }
        return "$\(p.formatted())"
    }

    private var roiText: String {
        guard tournament.totalInvestment > 0, let profit = tournament.profit else { return "—" }
        let roi = (Double(profit) / Double(tournament.totalInvestment)) * 100
        return String(format: "%.0f%%", roi)
    }

    private var peakStack: Int {
        tournament.sortedStackEntries.map(\.chipCount).max() ?? tournament.startingChips
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

    private func formatChipsShort(_ value: Int) -> String {
        if value >= 1_000_000 {
            let m = Double(value) / 1_000_000
            return m == m.rounded() ? String(format: "%.0fM", m) : String(format: "%.1fM", m)
        } else if value >= 10_000 {
            return String(format: "%.0fk", Double(value) / 1000)
        } else if value >= 1000 {
            let k = Double(value) / 1000
            return k == k.rounded() ? String(format: "%.0fk", k) : String(format: "%.1fk", k)
        }
        return "\(value)"
    }
}
