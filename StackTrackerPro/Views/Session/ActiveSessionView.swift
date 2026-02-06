import SwiftUI

struct ActiveSessionView: View {
    @Environment(TournamentManager.self) private var tournamentManager
    @Environment(ChatManager.self) private var chatManager

    @Bindable var tournament: Tournament
    @State private var messageText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Status bar (fixed top)
            StatusBarView(tournament: tournament)

            // Stack graph (~38% of available height)
            StackGraphView(
                entries: tournament.sortedStackEntries,
                averageStack: tournament.averageStack,
                startingChips: tournament.startingChips
            )
            .frame(maxHeight: .infinity, alignment: .top)
            .layoutPriority(0.38)

            Divider()
                .background(Color.borderSubtle)

            // Chat thread (fills remaining space)
            ChatThreadView(messages: tournament.sortedChatMessages)
                .frame(maxHeight: .infinity)
                .layoutPriority(0.62)

            // Chat input (fixed bottom)
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
