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

                // Hand notes pane
                HandNotesPane(cashSession: session)
                    .tag(2)

                // Structured hands pane
                HandsPane(
                    tournament: nil,
                    cashSession: session,
                    isReadOnly: session.status == .completed
                )
                .tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Chat input (fixed bottom, hidden for completed sessions)
            if session.status != .completed {
                CashChatInputView(
                    onAddOn: { showAddOnSheet = true },
                    onCashOut: { cashSessionManager.showEndSessionSheet() },
                    onHandNote: { selectedPage = 2 }
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
                        .fill(session.status == .active ? Color.mZoneGreen : Color.mZoneYellow)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(session.status.label)
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Session status: \(session.status.label)")
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
                        Label("Notes", systemImage: "note.text")
                    }

                    if session.status != .completed {
                        Divider()

                        Button(role: .destructive) {
                            cashSessionManager.showEndSessionSheet()
                        } label: {
                            Label("End Session", systemImage: "flag.checkered")
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
            if session.status != .completed {
                cashSessionManager.activeSession = session
                if session.status == .setup {
                    cashSessionManager.startSession(session)
                }
            }
        }
        .sheet(isPresented: Bindable(cashSessionManager).showEndSession) {
            EndCashSessionSheet(session: session)
        }
        .sheet(item: Binding(
            get: { cashSessionManager.showSessionRecap ? cashSessionManager.completedSessionForRecap : nil },
            set: { if $0 == nil { cashSessionManager.dismissRecap() } }
        )) { recapSession in
            CashSessionRecapSheet(session: recapSession) {
                cashSessionManager.dismissRecap()
            }
        }
        .sheet(isPresented: $showAddOnSheet) {
            addOnSheet
        }
    }

    // MARK: - Page Indicator

    private static let pageNames = ["Stack chart", "Stats", "Notes", "Hands"]

    private var pageIndicator: some View {
        // Buttons are 16pt wide with zero spacing so dot centers stay 16pt
        // apart — visually identical to the old 8pt dots + 8pt gaps, but with
        // a larger tappable area per dot.
        HStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { index in
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
        .accessibilityValue("Page \(selectedPage + 1) of 4, \(Self.pageNames[selectedPage])")
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
                .buttonStyle(PokerButtonStyle(isEnabled: (Int(addOnText) ?? 0) > 0))
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
