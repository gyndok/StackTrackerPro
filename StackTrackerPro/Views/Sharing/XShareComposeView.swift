import SwiftUI
import UIKit

struct XShareComposeView: View {
    let tournament: Tournament
    let context: TweetComposer.TweetContext

    @Environment(\.dismiss) private var dismiss
    @State private var tweetText = ""
    @State private var availableImages: [UIImage] = []
    @State private var selectedImageIndex: Int = 0

    private var remaining: Int {
        TweetComposer.remainingCharacters(for: tweetText)
    }

    private var isOverLimit: Bool {
        remaining < 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // MARK: - Tweet Section
                    sectionHeader("TWEET")

                    TextEditor(text: $tweetText)
                        .frame(minHeight: 120)
                        .padding(12)
                        .scrollContentBackground(.hidden)
                        .background(Color.cardSurface)
                        .foregroundColor(.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(isOverLimit ? Color.chipRed : Color.borderSubtle, lineWidth: 1)
                        )
                        .padding(.horizontal, 16)

                    // Character counter
                    HStack {
                        Spacer()
                        Text("\(remaining)")
                            .font(PokerTypography.chipLabel)
                            .foregroundColor(counterColor)
                    }
                    .padding(.horizontal, 20)

                    // MARK: - Image Section
                    if !availableImages.isEmpty {
                        sectionHeader("ATTACH IMAGE")

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(availableImages.indices, id: \.self) { index in
                                    Button {
                                        selectedImageIndex = index
                                    } label: {
                                        Image(uiImage: availableImages[index])
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 80, height: 80)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(
                                                        index == selectedImageIndex ? Color.goldAccent : Color.clear,
                                                        lineWidth: 2
                                                    )
                                            )
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        // Selected image preview
                        if selectedImageIndex < availableImages.count {
                            Image(uiImage: availableImages[selectedImageIndex])
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                                .padding(.horizontal, 24)
                        }
                    }

                    // MARK: - Share Button
                    Button {
                        shareToX()
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up.fill")
                            Text("Share")
                        }
                        .font(.headline.weight(.semibold))
                        .foregroundColor(.backgroundPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(isOverLimit ? Color.textSecondary : Color.goldAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(isOverLimit)
                    .padding(.horizontal, 24)
                }
                .padding(.vertical, 16)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Post to X")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.goldAccent)
                }
            }
        }
        .onAppear {
            tweetText = TweetComposer.composeTweet(for: tournament, context: context)
            renderImages()
        }
    }

    // MARK: - Helpers

    private var counterColor: Color {
        if remaining < 0 { return .chipRed }
        if remaining < 20 { return .mZoneOrange }
        return .textSecondary
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    @MainActor
    private func renderImages() {
        var images: [UIImage] = []

        // Render share card based on context
        switch context {
        case .activeLive:
            if let img = ShareCardRenderer.render(
                LiveStackFlexView(tournament: tournament, size: .square),
                size: .square
            ) {
                images.append(img)
            }
        case .completed:
            if let img = ShareCardRenderer.render(
                SessionRecapCardView(tournament: tournament, size: .square),
                size: .square
            ) {
                images.append(img)
            }
        }

        // Add chip stack photos (latest first, up to 3)
        let sortedPhotos = (tournament.chipStackPhotos ?? [])
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(3)

        for photo in sortedPhotos {
            if let uiImage = UIImage(data: photo.imageData) {
                images.append(uiImage)
            }
        }

        availableImages = images
    }

    private func shareToX() {
        var activityItems: [Any] = [tweetText]
        if selectedImageIndex < availableImages.count {
            activityItems.append(availableImages[selectedImageIndex])
        }

        let activityVC = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )

        // Find topmost view controller
        guard var topController = UIApplication.shared
            .connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        else { return }

        while let presented = topController.presentedViewController {
            topController = presented
        }

        // iPad popover anchor
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topController.view
            popover.sourceRect = CGRect(
                x: topController.view.bounds.midX,
                y: topController.view.bounds.midY,
                width: 0, height: 0
            )
            popover.permittedArrowDirections = []
        }

        topController.present(activityVC, animated: true)
    }
}
