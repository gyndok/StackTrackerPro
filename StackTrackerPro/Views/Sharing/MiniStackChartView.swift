import SwiftUI
import Charts

struct MiniStackChartView: View {
    let entries: [StackEntry]
    var height: CGFloat = 120

    /// Groups entries by blind level, keeps latest per level, sorted ascending.
    private var latestPerLevel: [StackEntry] {
        let grouped = Dictionary(grouping: entries) { $0.blindLevelNumber }
        return grouped.compactMap { (_, entriesForLevel) in
            entriesForLevel.max(by: { $0.timestamp < $1.timestamp })
        }
        .sorted { $0.blindLevelNumber < $1.blindLevelNumber }
    }

    var body: some View {
        let data = latestPerLevel

        if data.count >= 2 {
            Chart {
                ForEach(Array(data.enumerated()), id: \.offset) { index, entry in
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

                ForEach(Array(data.enumerated()), id: \.offset) { index, entry in
                    LineMark(
                        x: .value("Index", index),
                        y: .value("Chips", entry.chipCount)
                    )
                    .foregroundStyle(Color.goldAccent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: 0 ... max(data.count - 1, 1))
            .frame(height: height)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.cardSurface.opacity(0.3))
                .frame(height: height)
                .overlay {
                    Text("Not enough data for chart")
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)
                }
        }
    }
}
