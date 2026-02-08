import SwiftUI
import UIKit

// MARK: - Share Card Background

struct ShareCardBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(hex: "0D1117"),
                Color.backgroundPrimary,
                Color(hex: "0D1117")
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - App Watermark

struct AppWatermark: View {
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if let uiImage = UIImage(named: "AppIcon") {
                Image(uiImage: uiImage)
                    .resizable()
                    .frame(width: compact ? 16 : 24, height: compact ? 16 : 24)
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 4 : 6))
            }
            if !compact {
                Text("Stack Tracker Pro")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.textSecondary)
            }
        }
    }
}

// MARK: - Share Card Header

struct ShareCardHeader: View {
    let eventName: String
    var venueName: String?

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(eventName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)
                if let venue = venueName, !venue.isEmpty {
                    Text(venue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.textSecondary)
                }
            }
            Spacer()
            AppWatermark(compact: true)
        }
    }
}

// MARK: - Share Card Footer

struct ShareCardFooter: View {
    var body: some View {
        HStack {
            Spacer()
            AppWatermark(compact: false)
            Spacer()
        }
    }
}

// MARK: - Gold Divider

struct GoldDivider: View {
    var body: some View {
        LinearGradient(
            colors: [.clear, Color.goldAccent, .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
        .opacity(0.5)
    }
}
