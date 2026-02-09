import SwiftUI

struct BreakTimerSheet: View {
    @Bindable var tournament: Tournament
    @Environment(TournamentManager.self) private var tournamentManager
    @Environment(\.dismiss) private var dismiss

    // Setup state
    @State private var selectedDuration = 900 // 15 min default
    @State private var tableNumber = ""
    @State private var seatNumber = ""
    @State private var chipCountText = ""
    @State private var capturedPhoto: UIImage?
    @State private var showCamera = false

    private let durationPresets: [(label: String, seconds: Int)] = [
        ("5", 300), ("10", 600), ("15", 900), ("20", 1200), ("30", 1800)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if tournamentManager.isOnBreak, let endTime = tournamentManager.breakEndTime {
                    activeCountdownView(endTime: endTime)
                } else {
                    setupView
                }
            }
            .background(Color.backgroundPrimary)
            .navigationTitle(tournamentManager.isOnBreak ? "Break Timer" : "Take a Break")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.goldAccent)
                }
            }
        }
        .onAppear {
            if chipCountText.isEmpty, let latest = tournament.latestStack {
                chipCountText = "\(latest.chipCount)"
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraView { image in
                capturedPhoto = image
            }
        }
    }

    // MARK: - Setup View

    private var setupView: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Duration picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("BREAK DURATION")
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)

                    HStack(spacing: 0) {
                        ForEach(durationPresets, id: \.seconds) { preset in
                            Button {
                                selectedDuration = preset.seconds
                            } label: {
                                Text(preset.label)
                                    .font(PokerTypography.chipLabel)
                                    .foregroundColor(selectedDuration == preset.seconds ? .backgroundPrimary : .textPrimary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(selectedDuration == preset.seconds ? Color.goldAccent : Color.cardSurface)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text("minutes")
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, 16)

                // Table & Seat
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("TABLE")
                                .font(PokerTypography.chatCaption)
                                .foregroundColor(.textSecondary)
                            TextField("e.g. 42", text: $tableNumber)
                                .font(PokerTypography.chatBody)
                                .foregroundColor(.textPrimary)
                                .padding(10)
                                .background(Color.cardSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("SEAT")
                                .font(PokerTypography.chatCaption)
                                .foregroundColor(.textSecondary)
                            TextField("e.g. 7", text: $seatNumber)
                                .font(PokerTypography.chatBody)
                                .foregroundColor(.textPrimary)
                                .keyboardType(.numberPad)
                                .padding(10)
                                .background(Color.cardSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("CHIP COUNT")
                            .font(PokerTypography.chatCaption)
                            .foregroundColor(.textSecondary)
                        TextField("Chips", text: $chipCountText)
                            .font(PokerTypography.chatBody)
                            .foregroundColor(.textPrimary)
                            .keyboardType(.numberPad)
                            .padding(10)
                            .background(Color.cardSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal, 16)

                // Camera section
                VStack(alignment: .leading, spacing: 8) {
                    Text("CHIP PHOTO")
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)

                    if let photo = capturedPhoto {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: photo)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                            Button {
                                capturedPhoto = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(.white)
                                    .shadow(radius: 2)
                            }
                            .padding(6)
                        }
                    } else {
                        Button {
                            showCamera = true
                        } label: {
                            HStack {
                                Image(systemName: "camera.fill")
                                Text("Snap Your Chips")
                            }
                            .font(PokerTypography.chipLabel)
                            .foregroundColor(.goldAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.goldAccent.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.goldAccent.opacity(0.3), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)

                // Context bar
                if let blinds = tournament.currentBlinds, !blinds.isBreak {
                    HStack {
                        Text("Level \(tournament.currentDisplayLevel ?? blinds.levelNumber)")
                            .font(PokerTypography.chipLabel)
                            .foregroundColor(.textSecondary)
                        Spacer()
                        Text(blinds.blindsDisplay)
                            .font(PokerTypography.chipLabel)
                            .foregroundColor(.textSecondary)
                    }
                    .padding(10)
                    .background(Color.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 16)
                }

                // Start Break button
                Button {
                    startBreak()
                } label: {
                    Text("Start Break")
                        .font(.headline.weight(.semibold))
                        .foregroundColor(.backgroundPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(startButtonDisabled ? Color.gray.opacity(0.4) : Color.goldAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(startButtonDisabled)
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 16)
        }
    }

    private var startButtonDisabled: Bool {
        tableNumber.trimmingCharacters(in: .whitespaces).isEmpty ||
        seatNumber.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Active Countdown

    private func activeCountdownView(endTime: Date) -> some View {
        let latestBreak = tournament.sortedBreakEntries.last
        return ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 8)

                // Countdown timer
                TimelineView(.periodic(from: .now, by: 1.0)) { context in
                    let remaining = max(0, endTime.timeIntervalSince(context.date))
                    let minutes = Int(remaining) / 60
                    let seconds = Int(remaining) % 60
                    let progress = 1.0 - remaining / TimeInterval(latestBreak?.breakDurationSeconds ?? 900)
                    let timerColor = countdownColor(remaining: remaining)

                    VStack(spacing: 16) {
                        // Circular progress ring
                        ZStack {
                            Circle()
                                .stroke(Color.cardSurface, lineWidth: 8)
                                .frame(width: 200, height: 200)

                            Circle()
                                .trim(from: 0, to: CGFloat(min(progress, 1.0)))
                                .stroke(timerColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                .frame(width: 200, height: 200)
                                .rotationEffect(.degrees(-90))

                            if remaining > 0 {
                                Text(String(format: "%d:%02d", minutes, seconds))
                                    .font(PokerTypography.heroStat)
                                    .foregroundColor(timerColor)
                                    .monospacedDigit()
                            } else {
                                Text("BREAK OVER")
                                    .font(.title2.weight(.bold))
                                    .foregroundColor(.mZoneRed)
                                    .opacity(context.date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : 0.3)
                            }
                        }
                    }
                }

                // Info cards
                HStack(spacing: 12) {
                    infoCard(title: "TABLE", value: latestBreak?.tableNumber ?? "—")
                    infoCard(title: "SEAT", value: latestBreak?.seatNumber ?? "—")
                    infoCard(title: "CHIPS", value: (latestBreak?.chipCount ?? 0).formatted())
                }
                .padding(.horizontal, 16)

                // Photo thumbnail
                if let photoData = latestBreak?.chipPhotoData, let uiImage = UIImage(data: photoData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 16)
                }

                // End Break button
                Button {
                    tournamentManager.endBreak()
                } label: {
                    Text("End Break")
                        .font(.headline.weight(.semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.mZoneRed)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 16)

                Spacer()
            }
        }
    }

    private func infoCard(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(PokerTypography.chatCaption)
                .foregroundColor(.textSecondary)
            Text(value)
                .font(PokerTypography.statValue)
                .foregroundColor(.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func countdownColor(remaining: TimeInterval) -> Color {
        if remaining <= 0 {
            return .mZoneRed
        } else if remaining <= 120 {
            return .mZoneYellow
        } else {
            return .goldAccent
        }
    }

    // MARK: - Actions

    private func startBreak() {
        let chips = Int(chipCountText) ?? tournament.latestStack?.chipCount ?? 0
        let photoData = compressImage(capturedPhoto)

        tournamentManager.startBreak(
            tableNumber: tableNumber,
            seatNumber: seatNumber,
            chipCount: chips,
            duration: selectedDuration,
            photoData: photoData
        )
    }

    private func compressImage(_ image: UIImage?) -> Data? {
        guard let image else { return nil }
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
