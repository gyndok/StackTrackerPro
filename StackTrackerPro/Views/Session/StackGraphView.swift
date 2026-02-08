import SwiftUI
import Charts

struct StackGraphView: View {
    let entries: [StackEntry]
    let averageStack: Int
    let startingChips: Int
    var displayLevelNumbers: [Int: Int] = [:]

    @State private var showBB = false

    /// Groups entries by blind level, keeps only the latest entry per level, sorted ascending.
    private var latestPerLevel: [StackEntry] {
        let grouped = Dictionary(grouping: entries) { $0.blindLevelNumber }
        return grouped.compactMap { (_, entriesForLevel) in
            entriesForLevel.max(by: { $0.timestamp < $1.timestamp })
        }
        .sorted { $0.blindLevelNumber < $1.blindLevelNumber }
    }

    var body: some View {
        VStack(spacing: 8) {
            if !entries.isEmpty {
                // Compact segmented toggle
                Picker("Mode", selection: $showBB) {
                    Text("Chips").tag(false)
                    Text("BB").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
            }

            Group {
                if entries.isEmpty {
                    emptyGraph
                } else if showBB {
                    bbChart
                } else {
                    chipsChart
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Chips Chart (original)

    private var chipsChart: some View {
        let data = latestPerLevel
        let levelLabels = data.map { "Lvl \(displayLevelNumbers[$0.blindLevelNumber] ?? $0.blindLevelNumber)" }
        return Chart {
            ForEach(Array(data.enumerated()), id: \.offset) { index, entry in
                let label = levelLabels[index]
                AreaMark(
                    x: .value("Level", label),
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

            ForEach(Array(data.enumerated()), id: \.offset) { index, entry in
                let label = levelLabels[index]
                LineMark(
                    x: .value("Level", label),
                    y: .value("Chips", entry.chipCount)
                )
                .foregroundStyle(Color.goldAccent)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("Level", label),
                    y: .value("Chips", entry.chipCount)
                )
                .foregroundStyle(entry.mZone.color)
                .symbolSize(40)
            }

            if averageStack > 0 {
                RuleMark(y: .value("Average", averageStack))
                    .foregroundStyle(Color.textSecondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
                    .annotation(position: .trailing, alignment: .trailing) {
                        Text("Avg")
                            .font(.caption2)
                            .foregroundColor(.textSecondary)
                    }
            }

            RuleMark(y: .value("Start", startingChips))
                .foregroundStyle(Color.goldAccent.opacity(0.2))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .chartXScale(domain: levelLabels)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel {
                    if let chips = value.as(Int.self) {
                        Text(formatChipsShort(chips))
                            .font(.caption2)
                            .foregroundColor(.textSecondary)
                    }
                }
                AxisGridLine()
                    .foregroundStyle(Color.borderSubtle)
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label)
                            .font(.caption2)
                            .foregroundColor(.textSecondary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot
                .background(Color.cardSurface.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - BB Chart

    private var bbChart: some View {
        let data = latestPerLevel
        let levelLabels = data.map { "Lvl \(displayLevelNumbers[$0.blindLevelNumber] ?? $0.blindLevelNumber)" }
        return Chart {
            ForEach(Array(data.enumerated()), id: \.offset) { index, entry in
                let bb = entry.currentBB > 0 ? Double(entry.chipCount) / Double(entry.currentBB) : 0
                let label = levelLabels[index]

                AreaMark(
                    x: .value("Level", label),
                    y: .value("BB", bb)
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

            ForEach(Array(data.enumerated()), id: \.offset) { index, entry in
                let bb = entry.currentBB > 0 ? Double(entry.chipCount) / Double(entry.currentBB) : 0
                let zone = BBZone.from(bbCount: bb)
                let label = levelLabels[index]

                LineMark(
                    x: .value("Level", label),
                    y: .value("BB", bb)
                )
                .foregroundStyle(Color.goldAccent)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("Level", label),
                    y: .value("BB", bb)
                )
                .foregroundStyle(zone.color)
                .symbolSize(40)
            }

            if averageStack > 0, let lastEntry = data.last, lastEntry.currentBB > 0 {
                let avgBB = Double(averageStack) / Double(lastEntry.currentBB)
                RuleMark(y: .value("Average", avgBB))
                    .foregroundStyle(Color.textSecondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
                    .annotation(position: .trailing, alignment: .trailing) {
                        Text("Avg")
                            .font(.caption2)
                            .foregroundColor(.textSecondary)
                    }
            }
        }
        .chartXScale(domain: levelLabels)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel {
                    if let bb = value.as(Double.self) {
                        Text(String(format: "%.0f", bb))
                            .font(.caption2)
                            .foregroundColor(.textSecondary)
                    }
                }
                AxisGridLine()
                    .foregroundStyle(Color.borderSubtle)
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label)
                            .font(.caption2)
                            .foregroundColor(.textSecondary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot
                .background(Color.cardSurface.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Empty Graph

    private var emptyGraph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.cardSurface.opacity(0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.borderSubtle, lineWidth: 0.5)
                )

            VStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.title2)
                    .foregroundColor(.textSecondary.opacity(0.5))
                Text("Stack graph will appear here")
                    .font(PokerTypography.chatCaption)
                    .foregroundColor(.textSecondary)
            }
        }
    }

    private func formatChipsShort(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.0fM", Double(value) / 1_000_000)
        } else if value >= 1000 {
            return String(format: "%.0fk", Double(value) / 1000)
        }
        return "\(value)"
    }
}

#Preview {
    StackGraphView(entries: [], averageStack: 0, startingChips: 20000)
        .frame(height: 200)
        .background(Color.backgroundPrimary)
}
