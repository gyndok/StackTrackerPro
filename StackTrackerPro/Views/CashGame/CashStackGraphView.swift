import SwiftUI
import Charts

struct CashStackGraphView: View {
    let entries: [StackEntry]
    let buyInTotal: Int

    var body: some View {
        VStack(spacing: 8) {
            if entries.count < 2 {
                emptyGraph
            } else {
                chart
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Chart

    private var chart: some View {
        Chart {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                AreaMark(
                    x: .value("Update", index),
                    y: .value("Stack", entry.chipCount)
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

            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                LineMark(
                    x: .value("Update", index),
                    y: .value("Stack", entry.chipCount)
                )
                .foregroundStyle(Color.goldAccent)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("Update", index),
                    y: .value("Stack", entry.chipCount)
                )
                .foregroundStyle(entry.chipCount >= buyInTotal ? Color.mZoneGreen : Color.chipRed)
                .symbolSize(40)
            }

            // Buy-in reference line
            RuleMark(y: .value("Buy-in", buyInTotal))
                .foregroundStyle(Color.goldAccent.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .annotation(position: .trailing, alignment: .trailing) {
                    Text("Buy-in")
                        .font(.caption2)
                        .foregroundColor(.textSecondary)
                }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel {
                    if let dollars = value.as(Int.self) {
                        Text("$\(formatShort(dollars))")
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
                    if let index = value.as(Int.self) {
                        Text("#\(index + 1)")
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
                Text("Stack graph will appear after updates")
                    .font(PokerTypography.chatCaption)
                    .foregroundColor(.textSecondary)
            }
        }
        .frame(minHeight: 200)
    }

    // MARK: - Formatting

    private func formatShort(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.0fM", Double(value) / 1_000_000)
        } else if value >= 1000 {
            return String(format: "%.0fk", Double(value) / 1000)
        }
        return "\(value)"
    }
}

#Preview {
    CashStackGraphView(entries: [], buyInTotal: 300)
        .frame(height: 250)
        .background(Color.backgroundPrimary)
}
