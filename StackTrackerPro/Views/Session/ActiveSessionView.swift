import SwiftUI

struct ActiveSessionView: View {
    @Environment(TournamentManager.self) private var tournamentManager
    @Environment(ChatManager.self) private var chatManager

    @Bindable var tournament: Tournament
    @State private var messageText = ""
    @State private var selectedPage = 0

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
                    startingChips: tournament.startingChips
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
        Task {
            await chatManager.handleQuickAction(action)
        }
    }
}

#Preview {
    NavigationStack {
        ActiveSessionView(tournament: Tournament(name: "Preview Tournament"))
    }
    .environment(TournamentManager())
    .environment(ChatManager(tournamentManager: TournamentManager()))
}
