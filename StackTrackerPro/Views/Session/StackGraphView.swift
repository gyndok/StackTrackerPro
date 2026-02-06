import SwiftUI
import Charts

struct StackGraphView: View {
    let entries: [StackEntry]
    let averageStack: Int
    let startingChips: Int

    var body: some View {
        Group {
            if entries.isEmpty {
                emptyGraph
            } else {
                chart
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var chart: some View {
        Chart {
            // Stack line
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                LineMark(
                    x: .value("Time", entry.timestamp),
                    y: .value("Chips", entry.chipCount)
                )
                .foregroundStyle(Color.goldAccent)
                .lineStyle(StrokeStyle(lineWidth: 2))

                PointMark(
                    x: .value("Time", entry.timestamp),
                    y: .value("Chips", entry.chipCount)
                )
                .foregroundStyle(entry.mZone.color)
                .symbolSize(30)
            }

            // Average stack overlay
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

            // Starting stack reference
            RuleMark(y: .value("Start", startingChips))
                .foregroundStyle(Color.goldAccent.opacity(0.2))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
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
                    if let date = value.as(Date.self) {
                        Text(date.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundColor(.textSecondary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot
                .background(Color.cardSurface.opacity(0.3))
                .border(Color.borderSubtle, width: 0.5)
        }
    }

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
