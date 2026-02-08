import SwiftUI
import UIKit

struct ReceiptOverlayView: View {
    let photo: UIImage
    let eventName: String
    var venueName: String?
    var buyIn: String
    var result: String?
    var resultColor: Color = .green

    var body: some View {
        ZStack {
            // Photo background
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()

            // Top gradient overlay
            VStack {
                LinearGradient(
                    colors: [Color.black.opacity(0.7), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 100)
                Spacer()
            }

            // Bottom gradient overlay
            VStack {
                Spacer()
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 120)
            }

            // Top content: event + venue + watermark
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(eventName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                        if let venue = venueName, !venue.isEmpty {
                            Text(venue)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    Spacer()
                    AppWatermark(compact: true)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                Spacer()
            }

            // Bottom content: receipt label + buy-in + result
            VStack {
                Spacer()

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tournament Receipt")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.goldAccent)
                        Text(buyIn)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                    }
                    Spacer()
                    if let result {
                        Text(result)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(resultColor)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }
}
