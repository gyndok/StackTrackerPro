import SwiftUI

struct CashActiveSessionView: View {
    @Environment(CashSessionManager.self) private var cashSessionManager
    @AppStorage(SettingsKeys.keepScreenAwake) private var keepScreenAwake = true

    @Bindable var session: CashSession
    @State private var selectedPage = 0
    @State private var showAddOnSheet = false
    @State private var addOnText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Status bar (fixed top)
            CashSessionStatusBar(session: session)

            // Custom page indicator
            pageIndicator

            // Swipeable pager
            TabView(selection: $selectedPage) {
                // Chart pane
                CashStackGraphView(
                    entries: session.sortedStackEntries,
                    buyInTotal: session.buyInTotal
                )
                .tag(0)

                // Stats pane
                CashSessionStatsView(session: session)
                    .tag(1)

                // Hand notes placeholder (Task 9 will update HandNotesPane)
                handNotesPlaceholder
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Chat input (fixed bottom)
            CashChatInputView(
                onAddOn: { showAddOnSheet = true },
                onCashOut: { cashSessionManager.showEndSessionSheet() },
                onHandNote: { selectedPage = 2 }
            )
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
                        .fill(session.status == .active ? Color.mZoneGreen : Color.mZoneYellow)
                        .frame(width: 8, height: 8)
                    Text(session.status.label)
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if session.status == .active {
                        Button {
                            cashSessionManager.pauseSession()
                            HapticFeedback.impact(.light)
                        } label: {
                            Label("Pause", systemImage: "pause.circle")
                        }
                    } else if session.status == .paused {
                        Button {
                            cashSessionManager.resumeSession()
                            HapticFeedback.impact(.light)
                        } label: {
                            Label("Resume", systemImage: "play.circle")
                        }
                    }

                    Button {
                        selectedPage = 2
                    } label: {
                        Label("Hand Notes", systemImage: "note.text")
                    }

                    Divider()

                    Button(role: .destructive) {
                        cashSessionManager.showEndSessionSheet()
                    } label: {
                        Label("End Session", systemImage: "flag.checkered")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.goldAccent)
                }
            }
        }
        .onAppear {
            cashSessionManager.activeSession = session
            if session.status == .setup {
                cashSessionManager.startSession(session)
            }
        }
        .sheet(isPresented: Bindable(cashSessionManager).showEndSession) {
            EndCashSessionSheet(session: session)
        }
        .sheet(isPresented: Bindable(cashSessionManager).showSessionRecap) {
            if let recapSession = cashSessionManager.completedSessionForRecap {
                CashSessionRecapSheet(session: recapSession) {
                    cashSessionManager.dismissRecap()
                }
            }
        }
        .sheet(isPresented: $showAddOnSheet) {
            addOnSheet
        }
    }

    // MARK: - Page Indicator

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index == selectedPage ? Color.goldAccent : Color.textSecondary.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .animation(.spring(response: 0.3), value: selectedPage)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Hand Notes Placeholder

    private var handNotesPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "note.text")
                .font(.system(size: 40))
                .foregroundColor(.textSecondary.opacity(0.5))
            Text("Hand Notes")
                .font(.headline)
                .foregroundColor(.textSecondary)
            Text("Record notable hands during your session")
                .font(PokerTypography.chatCaption)
                .foregroundColor(.textSecondary.opacity(0.7))
                .multilineTextAlignment(.center)

            Button {
                cashSessionManager.addHandNote(text: "")
                HapticFeedback.impact(.light)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("Add Hand Note")
                }
                .quickChip()
            }

            if !session.sortedHandNotes.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(session.sortedHandNotes, id: \.persistentModelID) { note in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(note.descriptionText)
                                    .font(PokerTypography.chatBody)
                                    .foregroundColor(.textPrimary)
                                Text(note.timestamp, style: .time)
                                    .font(PokerTypography.chatCaption)
                                    .foregroundColor(.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .pokerCard()
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Add-On Sheet

    private var addOnSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("ADD-ON")
                    .font(PokerTypography.sectionHeader)
                    .foregroundColor(.goldAccent)

                VStack(spacing: 0) {
                    HStack {
                        Text("$")
                            .font(.title2.weight(.semibold))
                            .foregroundColor(.textSecondary)
                        TextField("Amount", text: $addOnText)
                            .keyboardType(.numberPad)
                            .font(.title2.weight(.semibold))
                            .foregroundColor(.textPrimary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
                .background(Color.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Button {
                    if let amount = Int(addOnText), amount > 0 {
                        cashSessionManager.addOn(amount: amount)
                        HapticFeedback.success()
                        addOnText = ""
                        showAddOnSheet = false
                    }
                } label: {
                    Text("Add Chips")
                }
                .buttonStyle(PokerButtonStyle(isEnabled: Int(addOnText) ?? 0 > 0))
                .disabled((Int(addOnText) ?? 0) <= 0)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .background(Color.backgroundPrimary)
            .navigationTitle("Add-on")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        addOnText = ""
                        showAddOnSheet = false
                    }
                    .foregroundColor(.textSecondary)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    NavigationStack {
        CashActiveSessionView(session: {
            let s = CashSession(stakes: "1/2", gameType: .nlh, buyInTotal: 300, venueName: "Bellagio")
            return s
        }())
    }
    .environment(CashSessionManager())
}
