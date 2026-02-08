import SwiftUI
import SwiftData
import PhotosUI

struct ChipStackPhotosPane: View {
    @Bindable var tournament: Tournament
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var fullScreenPhoto: ChipStackPhoto?

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Camera / photo picker buttons
                HStack(spacing: 12) {
                    Button {
                        showCamera = true
                    } label: {
                        HStack {
                            Image(systemName: "camera.fill")
                            Text("Camera")
                        }
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.goldAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.goldAccent.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.goldAccent.opacity(0.3), lineWidth: 1)
                        )
                    }

                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        HStack {
                            Image(systemName: "photo.on.rectangle")
                            Text("Library")
                        }
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.goldAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.goldAccent.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.goldAccent.opacity(0.3), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, 12)

                // Photo grid
                if sortedPhotos.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(sortedPhotos, id: \.persistentModelID) { photo in
                            photoThumbnail(photo)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 8)
        }
        .fullScreenCover(item: $fullScreenPhoto) { photo in
            fullScreenView(photo)
        }
        .sheet(isPresented: $showCamera) {
            CameraView { image in
                savePhoto(image)
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            if let newItem {
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        savePhoto(image)
                    }
                }
                selectedPhotoItem = nil
            }
        }
    }

    private var sortedPhotos: [ChipStackPhoto] {
        tournament.chipStackPhotos.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Thumbnail

    private func photoThumbnail(_ photo: ChipStackPhoto) -> some View {
        Button {
            fullScreenPhoto = photo
        } label: {
            ZStack(alignment: .bottomLeading) {
                if let uiImage = UIImage(data: photo.imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(minHeight: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.cardSurface)
                        .frame(minHeight: 100)
                }

                // Level badge
                Text("Lvl \(photo.blindLevel)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                deletePhoto(photo)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Full Screen

    private func fullScreenView(_ photo: ChipStackPhoto) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let uiImage = UIImage(data: photo.imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Metadata overlay
            VStack(alignment: .leading, spacing: 4) {
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    Text(photo.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(PokerTypography.chipLabel)
                    Text("Level \(photo.blindLevel)")
                        .font(PokerTypography.chipLabel)
                    if let stack = photo.stackAtTime {
                        Text("Stack: \(stack)")
                            .font(PokerTypography.chipLabel)
                    }
                }
                .foregroundColor(.white)
                .padding(12)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Close button
            Button {
                fullScreenPhoto = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundColor(.white.opacity(0.8))
                    .padding(16)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 60)

            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundColor(.textSecondary.opacity(0.5))

            Text("No chip stack photos yet")
                .font(PokerTypography.chatBody)
                .foregroundColor(.textSecondary)

            Text("Take photos to track your stack visually")
                .font(PokerTypography.chatCaption)
                .foregroundColor(.textSecondary.opacity(0.7))

            Spacer()
        }
    }

    // MARK: - Actions

    private func savePhoto(_ image: UIImage) {
        guard let compressed = compressImage(image) else { return }
        let photo = ChipStackPhoto(
            imageData: compressed,
            blindLevel: tournament.currentBlindLevelNumber,
            stackAtTime: tournament.latestStack?.chipCount
        )
        tournament.chipStackPhotos.append(photo)
    }

    private func deletePhoto(_ photo: ChipStackPhoto) {
        tournament.chipStackPhotos.removeAll { $0.persistentModelID == photo.persistentModelID }
    }

    private func compressImage(_ image: UIImage) -> Data? {
        let maxDimension: CGFloat = 1200
        let size = image.size

        if size.width > maxDimension || size.height > maxDimension {
            let scale = maxDimension / max(size.width, size.height)
            let newSize = CGSize(width: size.width * scale, height: size.height * scale)
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            image.draw(in: CGRect(origin: .zero, size: newSize))
            let resized = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            return resized?.jpegData(compressionQuality: 0.7)
        }

        return image.jpegData(compressionQuality: 0.7)
    }
}

// Make ChipStackPhoto identifiable for fullScreenCover
extension ChipStackPhoto: Identifiable {
    var id: PersistentIdentifier { persistentModelID }
}

#Preview {
    ChipStackPhotosPane(tournament: Tournament(name: "Preview", startingChips: 20000))
        .background(Color.backgroundPrimary)
}
