import SwiftUI
import PhotosUI

struct ReceiptCapturePane: View {
    @Bindable var tournament: Tournament
    @State private var showCamera = false
    @State private var showFullScreen = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showReceiptShare = false
    @State private var receiptShareImage: UIImage?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let imageData = tournament.receiptImageData,
                   let uiImage = UIImage(data: imageData) {
                    // Receipt captured
                    ZStack(alignment: .topTrailing) {
                        Button {
                            showFullScreen = true
                        } label: {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.borderSubtle, lineWidth: 0.5)
                                )
                        }

                        // Re-capture buttons
                        VStack(spacing: 8) {
                            Button {
                                shareReceipt()
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                                    .padding(8)
                                    .background(Color.goldAccent.opacity(0.9))
                                    .clipShape(Circle())
                                    .shadow(radius: 4)
                            }

                            Button {
                                showCamera = true
                            } label: {
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                                    .padding(8)
                                    .background(Color.goldAccent.opacity(0.9))
                                    .clipShape(Circle())
                                    .shadow(radius: 4)
                            }

                            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                                    .padding(8)
                                    .background(Color.goldAccent.opacity(0.9))
                                    .clipShape(Circle())
                                    .shadow(radius: 4)
                            }
                        }
                        .padding(12)
                    }
                } else {
                    // No receipt
                    VStack(spacing: 16) {
                        Spacer().frame(height: 60)

                        // Camera + Library buttons
                        HStack(spacing: 12) {
                            Button {
                                showCamera = true
                            } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 32))
                                        .foregroundColor(.goldAccent.opacity(0.6))
                                    Text("Camera")
                                        .font(PokerTypography.chipLabel)
                                        .foregroundColor(.textSecondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 30)
                                .background(Color.cardSurface.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.goldAccent.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [8, 4]))
                                )
                            }

                            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                VStack(spacing: 8) {
                                    Image(systemName: "photo.on.rectangle")
                                        .font(.system(size: 32))
                                        .foregroundColor(.goldAccent.opacity(0.6))
                                    Text("Library")
                                        .font(PokerTypography.chipLabel)
                                        .foregroundColor(.textSecondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 30)
                                .background(Color.cardSurface.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.goldAccent.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [8, 4]))
                                )
                            }
                        }

                        Text("Capture your buy-in receipt")
                            .font(PokerTypography.chatCaption)
                            .foregroundColor(.textSecondary.opacity(0.7))

                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $showCamera) {
            CameraView { image in
                saveReceipt(image)
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            receiptFullScreen
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            if let newItem {
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        saveReceipt(image)
                    }
                }
                selectedPhotoItem = nil
            }
        }
    }

    // MARK: - Full Screen Receipt

    private var receiptFullScreen: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let imageData = tournament.receiptImageData,
               let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Spacer()
                Button { shareReceipt() } label: {
                    Image(systemName: "square.and.arrow.up.circle.fill")
                        .font(.title)
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.trailing, 4)
                }
                Button { showFullScreen = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            .padding(16)
        }
        .sheet(isPresented: $showReceiptShare) {
            if let image = receiptShareImage {
                PhotoOverlayShareSheet(image: image, eventName: tournament.name)
            }
        }
    }

    // MARK: - Share

    private func shareReceipt() {
        guard let imageData = tournament.receiptImageData,
              let uiImage = UIImage(data: imageData) else { return }

        let buyInText = "$\(tournament.totalInvestment.formatted())"

        var resultText: String? = nil
        var resultColor: Color = .green
        if let profit = tournament.profit {
            resultText = profit >= 0 ? "+$\(profit.formatted())" : "-$\(abs(profit).formatted())"
            resultColor = profit >= 0 ? .green : .red
        }

        let overlayView = ReceiptOverlayView(
            photo: uiImage,
            eventName: tournament.name,
            venueName: tournament.venueName,
            buyIn: buyInText,
            result: resultText,
            resultColor: resultColor
        )

        let photoAspect = uiImage.size.height / uiImage.size.width
        let renderWidth: CGFloat = 360
        let renderHeight = renderWidth * photoAspect

        let renderer = ImageRenderer(content:
            overlayView.frame(width: renderWidth, height: renderHeight)
        )
        renderer.scale = 3.0
        receiptShareImage = renderer.uiImage
        showReceiptShare = true
    }

    // MARK: - Actions

    private func saveReceipt(_ image: UIImage) {
        let maxDimension: CGFloat = 1200
        let size = image.size

        if size.width > maxDimension || size.height > maxDimension {
            let scale = maxDimension / max(size.width, size.height)
            let newSize = CGSize(width: size.width * scale, height: size.height * scale)
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            image.draw(in: CGRect(origin: .zero, size: newSize))
            let resized = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            tournament.receiptImageData = resized?.jpegData(compressionQuality: 0.7)
        } else {
            tournament.receiptImageData = image.jpegData(compressionQuality: 0.7)
        }
    }
}

#Preview {
    ReceiptCapturePane(tournament: Tournament(name: "Preview", startingChips: 20000))
        .background(Color.backgroundPrimary)
}
