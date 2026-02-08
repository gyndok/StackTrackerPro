import SwiftUI

struct ActiveSessionView: View {
    @Environment(TournamentManager.self) private var tournamentManager
    @Environment(ChatManager.self) private var chatManager

    @Bindable var tournament: Tournament
    @State private var messageText = ""
    @State private var selectedPage = 0
    @State private var showLiveShare = false

    var body: some View {
        VStack(spacing: 0) {
            // Status bar (fixed top)
            StatusBarView(tournament: tournament)

            // Custom page indicator
            pageIndicator

            // Swipeable pager
            TabView(selection: $selectedPage) {
                // Chart pane
                StackGraphView(
                    entries: tournament.sortedStackEntries,
                    averageStack: tournament.averageStack,
                    startingChips: tournament.startingChips,
                    displayLevelNumbers: tournament.displayLevelNumbers
                )
                .tag(0)

                // Metrics pane
                TournamentMetricsView(tournament: tournament)
                    .tag(1)

                // Blind levels pane
                BlindLevelsPane(tournament: tournament)
                    .tag(2)

                // Photos pane
                ChipStackPhotosPane(tournament: tournament)
                    .tag(3)

                // Receipt pane
                ReceiptCapturePane(tournament: tournament)
                    .tag(4)

                // Chat pane
                ChatThreadView(messages: tournament.sortedChatMessages)
                    .tag(5)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Chat input (fixed bottom, all panes)
            ChatInputView(
                text: $messageText,
                isProcessing: chatManager.isProcessing,
                onSend: sendMessage,
                onQuickAction: handleQuickAction
            )
        }
        .background(Color.backgroundPrimary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(tournament.status == .active ? Color.mZoneGreen : Color.mZoneYellow)
                        .frame(width: 8, height: 8)
                    Text(tournament.status.label)
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if tournament.status == .active {
                        Button {
                            tournamentManager.pauseTournament()
                        } label: {
                            Label("Pause", systemImage: "pause.circle")
                        }
                    } else if tournament.status == .paused {
                        Button {
                            tournamentManager.resumeTournament()
                        } label: {
                            Label("Resume", systemImage: "play.circle")
                        }
                    }

                    Button {
                        Task {
                            await chatManager.handleQuickAction(.stats)
                        }
                    } label: {
                        Label("Session Summary", systemImage: "chart.bar")
                    }

                    Button {
                        showLiveShare = true
                    } label: {
                        Label("Share Stack", systemImage: "square.and.arrow.up")
                    }

                    Divider()

                    Button(role: .destructive) {
                        tournamentManager.showEndTournamentSheet()
                    } label: {
                        Label("End Tournament", systemImage: "flag.checkered")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.goldAccent)
                }
            }
        }
        .onAppear {
            tournamentManager.activeTournament = tournament
            if tournament.status == .setup {
                tournamentManager.startTournament(tournament)
            }
        }
        .sheet(isPresented: Bindable(tournamentManager).showSessionRecap) {
            if let recapTournament = tournamentManager.completedTournamentForRecap {
                SessionRecapSheet(tournament: recapTournament) {
                    tournamentManager.dismissRecap()
                }
            }
        }
        .sheet(isPresented: Bindable(tournamentManager).showEndTournament) {
            EndTournamentSheet(tournament: tournament)
        }
        .sheet(isPresented: $showLiveShare) {
            LiveShareSheet(tournament: tournament)
        }
    }

    // MARK: - Page Indicator

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { index in
                Circle()
                    .fill(index == selectedPage ? Color.goldAccent : Color.textSecondary.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .animation(.spring(response: 0.3), value: selectedPage)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = messageText
        messageText = ""
        Task {
            await chatManager.processUserMessage(text: text)
        }
    }

    private func handleQuickAction(_ action: QuickAction) {
        if action == .share {
            showLiveShare = true
            return
        }
        Task {
            await chatManager.handleQuickAction(action)
        }
    }
}

// MARK: - Live Share Sheet

struct LiveShareSheet: View {
    let tournament: Tournament
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSize: ShareCardSize = .stories
    @State private var renderedImage: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Size", selection: $selectedSize) {
                        ForEach(ShareCardSize.allCases, id: \.self) { size in
                            Text(size.rawValue).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    if let image = renderedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                            .padding(.horizontal, 24)
                    } else {
                        ProgressView()
                            .frame(height: 300)
                    }

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
                }
                .padding(.vertical, 16)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Share Stack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.goldAccent)
                }
            }
        }
        .onAppear { renderCard() }
        .onChange(of: selectedSize) { _, _ in renderCard() }
    }

    private func renderCard() {
        let card = LiveStackFlexView(tournament: tournament, size: selectedSize)
        renderedImage = ShareCardRenderer.render(card, size: selectedSize)
    }
}

#Preview {
    NavigationStack {
        ActiveSessionView(tournament: Tournament(name: "Preview Tournament"))
    }
    .environment(TournamentManager())
    .environment(ChatManager(tournamentManager: TournamentManager()))
}
