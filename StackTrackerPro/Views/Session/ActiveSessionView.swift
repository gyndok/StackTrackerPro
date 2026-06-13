import SwiftUI

struct ActiveSessionView: View {
    @Environment(TournamentManager.self) private var tournamentManager
    @Environment(ChatManager.self) private var chatManager

    @AppStorage(SettingsKeys.keepScreenAwake) private var keepScreenAwake = true

    @Bindable var tournament: Tournament
    @State private var messageText = ""
    @State private var selectedPage = 0
    @State private var showLiveShare = false
    @State private var showXShare = false
    @State private var showBreakTimer = false
    @State private var showVideoExport = false
    @State private var showEditResult = false

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

                // Hand notes pane
                HandNotesPane(tournament: tournament)
                    .tag(5)

                // Chat pane
                ChatThreadView(messages: tournament.sortedChatMessages)
                    .tag(6)

                // Scouting report pane
                ScoutingReportView(tournament: tournament)
                    .tag(7)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Chat input (fixed bottom, hidden for completed tournaments)
            if tournament.status != .completed {
                ChatInputView(
                    text: $messageText,
                    isProcessing: chatManager.isProcessing,
                    onSend: sendMessage,
                    onQuickAction: handleQuickAction
                )
            }
        }
        .background(Color.backgroundPrimary)
        .onChange(of: keepScreenAwake, initial: true) { _, newValue in
            UIApplication.shared.isIdleTimerDisabled = newValue
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(tournament.status == .active ? Color.mZoneGreen : Color.mZoneYellow)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(tournament.status.label)
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Tournament status: \(tournament.status.label)")
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

                    if tournament.status != .completed {
                        Button {
                            Task {
                                await chatManager.handleQuickAction(.stats)
                            }
                        } label: {
                            Label("Session Summary", systemImage: "chart.bar")
                        }

                        Button {
                            showBreakTimer = true
                        } label: {
                            Label(
                                tournamentManager.isOnBreak ? "Break Timer" : "Take a Break",
                                systemImage: "cup.and.saucer"
                            )
                        }
                    }

                    Button {
                        selectedPage = 5
                    } label: {
                        Label("Hand Notes", systemImage: "note.text")
                    }

                    Button {
                        selectedPage = 7
                    } label: {
                        Label("Scouting Report", systemImage: "doc.text.magnifyingglass")
                    }

                    Button {
                        showLiveShare = true
                    } label: {
                        Label("Share Stack", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        showXShare = true
                    } label: {
                        Label("Post to X", systemImage: "square.and.arrow.up.fill")
                    }

                    if !tournament.sortedStackEntries.isEmpty {
                        Button {
                            showVideoExport = true
                        } label: {
                            Label("Create Video", systemImage: "film")
                        }
                    }

                    if tournament.status == .completed {
                        Divider()

                        Button {
                            showEditResult = true
                        } label: {
                            Label("Edit Result", systemImage: "pencil.circle")
                        }
                    }

                    if tournament.status != .completed {
                        Divider()

                        Button(role: .destructive) {
                            tournamentManager.showEndTournamentSheet()
                        } label: {
                            Label("End Tournament", systemImage: "flag.checkered")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.goldAccent)
                }
                .accessibilityLabel("Session options")
            }
        }
        .onAppear {
            // Completed tournaments are shown read-only (pushed from history/
            // results) — never touch manager state for them.
            guard tournament.status != .completed else { return }
            tournamentManager.activeTournament = tournament
            if tournament.status == .setup {
                tournamentManager.startTournament(tournament)
            }
            // Paused tournaments stay paused — resuming requires the explicit
            // Resume action in the toolbar menu.
        }
        .sheet(item: Binding(
            get: { tournamentManager.showSessionRecap ? tournamentManager.completedTournamentForRecap : nil },
            set: { if $0 == nil { tournamentManager.dismissRecap() } }
        )) { recapTournament in
            SessionRecapSheet(tournament: recapTournament) {
                tournamentManager.dismissRecap()
            }
        }
        .sheet(isPresented: Bindable(tournamentManager).showEndTournament) {
            EndTournamentSheet(tournament: tournament)
        }
        .sheet(isPresented: $showLiveShare) {
            LiveShareSheet(tournament: tournament)
        }
        .sheet(isPresented: $showXShare) {
            XShareComposeView(
                tournament: tournament,
                context: tournament.status == .completed ? .completed : .activeLive
            )
        }
        .sheet(isPresented: $showBreakTimer) {
            BreakTimerSheet(tournament: tournament)
        }
        .sheet(isPresented: $showEditResult) {
            EditResultSheet(tournament: tournament)
        }
        .fullScreenCover(isPresented: $showVideoExport) {
            VideoExportSheet(tournament: tournament)
        }
    }

    // MARK: - Page Indicator

    private static let pageNames = [
        "Stack chart", "Metrics", "Blind levels", "Photos",
        "Receipts", "Hand notes", "Chat", "Scouting report"
    ]

    private var pageIndicator: some View {
        // Buttons are 16pt wide with zero spacing so dot centers stay 16pt
        // apart — visually identical to the old 8pt dots + 8pt gaps, but with
        // a larger tappable area per dot.
        HStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { index in
                Button {
                    selectedPage = index
                } label: {
                    Circle()
                        .fill(index == selectedPage ? Color.goldAccent : Color.textSecondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .animation(.spring(response: 0.3), value: selectedPage)
                        .frame(width: 16, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.pageNames[index])
                .accessibilityAddTraits(index == selectedPage ? [.isSelected] : [])
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page indicator")
        .accessibilityValue("Page \(selectedPage + 1) of 8, \(Self.pageNames[selectedPage])")
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
