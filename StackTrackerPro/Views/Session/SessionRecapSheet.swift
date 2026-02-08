import SwiftUI
import SwiftData

struct SessionRecapSheet: View {
    let tournament: Tournament
    let onDismiss: () -> Void

    @AppStorage(SettingsKeys.milestoneCelebrations) private var milestoneCelebrations = true

    @State private var selectedSize: ShareCardSize = .stories
    @State private var renderedImage: UIImage?
    @State private var milestones: [MilestoneType] = []
    @State private var showMilestone = false
    @State private var currentMilestone: MilestoneType?
    @State private var showXShare = false

    @Query private var allTournaments: [Tournament]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Size picker
                    Picker("Size", selection: $selectedSize) {
                        ForEach(ShareCardSize.allCases, id: \.self) { size in
                            Text(size.rawValue).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    // Card preview
                    if let image = renderedImage {
                        let aspect = CGFloat(image.size.height) / CGFloat(image.size.width)
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                            .padding(.horizontal, 24)
                            .aspectRatio(1 / aspect, contentMode: .fit)
                    } else {
                        ProgressView()
                            .frame(height: 300)
                    }

                    // Share button
                    if let uiImage = renderedImage {
                        let shareImage = ShareableImage(
                            image: Image(uiImage: uiImage),
                            uiImage: uiImage
                        )
                        ShareLink(
                            item: shareImage,
                            preview: SharePreview(
                                tournament.name,
                                image: Image(uiImage: uiImage)
                            )
                        ) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("Share")
                            }
                            .font(.headline.weight(.semibold))
                            .foregroundColor(.backgroundPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.goldAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.horizontal, 24)
                    }

                    // Post to X button
                    Button {
                        showXShare = true
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up.fill")
                            Text("Post to X")
                        }
                        .font(.headline.weight(.semibold))
                        .foregroundColor(.goldAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.goldAccent.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.goldAccent.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.vertical, 16)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Session Recap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onDismiss()
                    }
                    .foregroundColor(.goldAccent)
                }
            }
        }
        .onAppear {
            renderCard()
            checkMilestones()
        }
        .onChange(of: selectedSize) { _, _ in
            renderCard()
        }
        .sheet(isPresented: $showMilestone) {
            if let milestone = currentMilestone {
                milestoneSheet(milestone)
            }
        }
        .sheet(isPresented: $showXShare) {
            XShareComposeView(tournament: tournament, context: .completed)
        }
    }

    // MARK: - Rendering

    private func renderCard() {
        let card = SessionRecapCardView(tournament: tournament, size: selectedSize)
        renderedImage = ShareCardRenderer.render(card, size: selectedSize)
    }

    // MARK: - Milestones

    private func checkMilestones() {
        guard milestoneCelebrations else { return }
        milestones = MilestoneTracker.shared.checkForNewMilestones(
            completed: tournament,
            allTournaments: allTournaments
        )
        if let first = milestones.first {
            currentMilestone = first
            MilestoneTracker.shared.markShown(milestones)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                showMilestone = true
            }
        }
    }

    // MARK: - Milestone Sheet

    private func milestoneSheet(_ milestone: MilestoneType) -> some View {
        NavigationStack {
            let detail = milestoneDetail(milestone)
            let card = MilestoneCardView(milestone: milestone, detail: detail, size: .stories)

            VStack(spacing: 16) {
                if let image = ShareCardRenderer.render(card, size: .stories) {
                    let shareImage = ShareableImage(
                        image: Image(uiImage: image),
                        uiImage: image
                    )

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                        .padding(.horizontal, 24)

                    ShareLink(
                        item: shareImage,
                        preview: SharePreview(
                            milestone.title,
                            image: Image(uiImage: image)
                        )
                    ) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share Milestone")
                        }
                        .font(.headline.weight(.semibold))
                        .foregroundColor(.backgroundPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.goldAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 24)
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color.backgroundPrimary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        showMilestone = false
                    }
                    .foregroundColor(.goldAccent)
                }
            }
        }
    }

    private func milestoneDetail(_ milestone: MilestoneType) -> String {
        switch milestone {
        case .firstCash:
            let payout = tournament.payout ?? 0
            return "$\(payout.formatted()) at \(tournament.venueName ?? tournament.name)"
        case .firstPlace:
            return "Winner of \(tournament.name)"
        case .newPBCash:
            let payout = tournament.payout ?? 0
            return "$\(payout.formatted()) — new personal best"
        case .finalTable:
            let pos = tournament.finishPosition ?? 0
            return "\(ordinal(pos)) of \(tournament.fieldSize) players"
        }
    }

    private func ordinal(_ n: Int) -> String {
        let ones = n % 10
        let tens = (n / 10) % 10
        if tens == 1 { return "\(n)th" }
        switch ones {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }
}
