# Cash Game Tracking & CSV Import — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a full cash game tracking section with live session tracking, a unified Results tab combining cash and tournaments with cumulative P/L graph and filters, and CSV import for bulk session history.

**Architecture:** Separate `CashSession` SwiftData model alongside `Tournament`. Shared `PokerSession` protocol enables the unified Results tab. `CashSessionManager` mirrors `TournamentManager` for cash-specific state. Existing models (`StackEntry`, `ChatMessage`, `HandNote`) gain optional `cashSession` relationships so they can belong to either session type. CSV import via `CSVImporter` utility creates completed `CashSession` or `Tournament` objects from file.

**Tech Stack:** SwiftUI, SwiftData, SwiftUI Charts, CloudKit (private DB), UniformTypeIdentifiers (CSV import)

---

### Task 1: Add `SessionStatus` enum and `CashSession` model

**Files:**
- Modify: `StackTrackerPro/Models/Enums.swift`
- Create: `StackTrackerPro/Models/CashSession.swift`

**Step 1: Add SessionStatus enum to Enums.swift**

Add after the existing `TournamentStatus` enum (line 37):

```swift
// MARK: - Session Status (shared by cash games)

enum SessionStatus: String, Codable, CaseIterable {
    case setup = "setup"
    case active = "active"
    case paused = "paused"
    case completed = "completed"

    var label: String {
        switch self {
        case .setup: return "Setup"
        case .active: return "Active"
        case .paused: return "Paused"
        case .completed: return "Completed"
        }
    }

    var icon: String {
        switch self {
        case .setup: return "gear"
        case .active: return "play.circle.fill"
        case .paused: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .setup: return .textSecondary
        case .active: return .mZoneGreen
        case .paused: return .mZoneYellow
        case .completed: return .goldAccent
        }
    }
}
```

**Step 2: Create CashSession.swift**

```swift
import Foundation
import SwiftData

@Model
final class CashSession {
    // Basic info
    var date: Date = Date.now
    var startTime: Date = Date.now
    var endTime: Date?
    var stakes: String = ""
    var gameTypeRaw: String = "NLH"
    var buyInTotal: Int = 0
    var cashOut: Int?
    var venueName: String?
    var venueID: UUID?
    var statusRaw: String = "setup"
    var notes: String?
    var isImported: Bool = false

    // Relationships
    @Relationship(deleteRule: .cascade, inverse: \StackEntry.cashSession)
    var stackEntries: [StackEntry]? = []

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.cashSession)
    var chatMessages: [ChatMessage]? = []

    @Relationship(deleteRule: .cascade, inverse: \HandNote.cashSession)
    var handNotes: [HandNote]? = []

    init(
        stakes: String = "",
        gameType: GameType = .nlh,
        buyInTotal: Int = 0,
        venueName: String? = nil,
        date: Date = .now
    ) {
        self.date = date
        self.startTime = date
        self.endTime = nil
        self.stakes = stakes
        self.gameTypeRaw = gameType.rawValue
        self.buyInTotal = buyInTotal
        self.cashOut = nil
        self.venueName = venueName
        self.venueID = nil
        self.statusRaw = SessionStatus.setup.rawValue
        self.notes = nil
        self.isImported = false
    }

    // MARK: - Computed Properties

    var gameType: GameType {
        get { GameType(rawValue: gameTypeRaw) ?? .nlh }
        set { gameTypeRaw = newValue.rawValue }
    }

    var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .setup }
        set { statusRaw = newValue.rawValue }
    }

    var profit: Int? {
        guard let cashOut else { return nil }
        return cashOut - buyInTotal
    }

    var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }

    var durationFormatted: String {
        let elapsed = duration ?? Date.now.timeIntervalSince(startTime)
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    var hourlyRate: Double? {
        guard let profit, let dur = duration, dur > 0 else { return nil }
        return Double(profit) / (dur / 3600)
    }

    var sortedStackEntries: [StackEntry] {
        (stackEntries ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    var sortedChatMessages: [ChatMessage] {
        (chatMessages ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    var sortedHandNotes: [HandNote] {
        (handNotes ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    var latestStack: StackEntry? {
        sortedStackEntries.last
    }

    var displayName: String {
        "\(stakes) \(gameType.label)"
    }
}
```

**Step 3: Commit**

```bash
git add StackTrackerPro/Models/CashSession.swift StackTrackerPro/Models/Enums.swift
git commit -m "feat: add CashSession model and SessionStatus enum"
```

---

### Task 2: Update existing models with optional `cashSession` relationships

**Files:**
- Modify: `StackTrackerPro/Models/StackEntry.swift`
- Modify: `StackTrackerPro/Models/ChatMessage.swift`
- Modify: `StackTrackerPro/Models/HandNote.swift`

**Step 1: Add cashSession relationship to StackEntry.swift**

Add after line 13 (`var tournament: Tournament?`):

```swift
    var cashSession: CashSession?
```

**Step 2: Add cashSession relationship to ChatMessage.swift**

Add after line 11 (`var tournament: Tournament?`):

```swift
    var cashSession: CashSession?
```

**Step 3: Add cashSession relationship to HandNote.swift**

Add after line 12 (`var tournament: Tournament?`):

```swift
    var cashSession: CashSession?
```

**Step 4: Commit**

```bash
git add StackTrackerPro/Models/StackEntry.swift StackTrackerPro/Models/ChatMessage.swift StackTrackerPro/Models/HandNote.swift
git commit -m "feat: add cashSession relationship to StackEntry, ChatMessage, HandNote"
```

---

### Task 3: Register CashSession in SwiftData schema

**Files:**
- Modify: `StackTrackerPro/App/StackTrackerProApp.swift`

**Step 1: Add CashSession to schema array**

In `StackTrackerProApp.swift`, add `CashSession.self` to the schema array (after line 12, `Tournament.self`):

```swift
        let schema = Schema([
            Tournament.self,
            CashSession.self,
            BlindLevel.self,
            StackEntry.self,
            ChatMessage.self,
            HandNote.self,
            BountyEvent.self,
            FieldSnapshot.self,
            Venue.self,
            ChipStackPhoto.self,
        ])
```

**Step 2: Commit**

```bash
git add StackTrackerPro/App/StackTrackerProApp.swift
git commit -m "feat: register CashSession in SwiftData schema"
```

---

### Task 4: Create CashSessionManager

**Files:**
- Create: `StackTrackerPro/Managers/CashSessionManager.swift`

**Step 1: Create CashSessionManager.swift**

```swift
import Foundation
import SwiftData
import Observation

@MainActor @Observable
final class CashSessionManager {
    var activeSession: CashSession?
    var modelContext: ModelContext?

    // End session state
    var showEndSession = false
    var showSessionRecap = false
    private(set) var completedSessionForRecap: CashSession?

    init() {}

    func setContext(_ context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - State Machine

    func startSession(_ session: CashSession) {
        session.status = .active
        session.startTime = .now
        activeSession = session

        // Record initial stack entry (buy-in as dollar amount)
        let entry = StackEntry(
            chipCount: session.buyInTotal,
            source: .initial
        )
        session.stackEntries?.append(entry)

        save()
    }

    func pauseSession() {
        activeSession?.status = .paused
        save()
    }

    func resumeSession() {
        activeSession?.status = .active
        save()
    }

    func completeSession(cashOut: Int, endTime: Date = .now) {
        guard let session = activeSession else { return }
        session.status = .completed
        session.cashOut = cashOut
        session.endTime = endTime
        save()
        completedSessionForRecap = session
        showSessionRecap = true
    }

    func showEndSessionSheet() {
        showEndSession = true
    }

    func dismissRecap() {
        showSessionRecap = false
        completedSessionForRecap = nil
        activeSession = nil
    }

    // MARK: - Updates

    func updateStack(dollarAmount: Int) {
        guard let session = activeSession else { return }
        let entry = StackEntry(
            chipCount: dollarAmount,
            source: .chat
        )
        session.stackEntries?.append(entry)
        save()
    }

    func addOn(amount: Int) {
        guard let session = activeSession else { return }
        session.buyInTotal += amount
        save()
    }

    func recordHandNote(_ text: String) {
        guard let session = activeSession else { return }
        let note = HandNote(
            descriptionText: text,
            stackBefore: session.latestStack?.chipCount,
            blindsDisplay: session.stakes
        )
        session.handNotes?.append(note)
        save()
    }

    func addHandNote(text: String, stackBefore: Int? = nil) {
        guard let session = activeSession else { return }
        let note = HandNote(
            descriptionText: text,
            stackBefore: stackBefore ?? session.latestStack?.chipCount,
            blindsDisplay: session.stakes
        )
        session.handNotes?.append(note)
        save()
    }

    func updateHandNote(_ note: HandNote, text: String) {
        note.descriptionText = text
        save()
    }

    func deleteHandNote(_ note: HandNote) {
        guard let session = activeSession else { return }
        session.handNotes?.removeAll { $0.persistentModelID == note.persistentModelID }
        modelContext?.delete(note)
        save()
    }

    // MARK: - Persistence

    private func save() {
        try? modelContext?.save()
    }
}
```

**Step 2: Commit**

```bash
git add StackTrackerPro/Managers/CashSessionManager.swift
git commit -m "feat: add CashSessionManager for cash game state management"
```

---

### Task 5: Wire CashSessionManager into the app

**Files:**
- Modify: `StackTrackerPro/App/StackTrackerProApp.swift`

**Step 1: Add CashSessionManager state**

Add after line 7 (`@State private var chatManager: ChatManager?`):

```swift
    @State private var cashSessionManager = CashSessionManager()
```

**Step 2: Set context and inject environment**

In the body, after `tournamentManager.setContext(sharedModelContainer.mainContext)` (line 54), add:

```swift
                        cashSessionManager.setContext(sharedModelContainer.mainContext)
```

After `.environment(chatManager ?? ChatManager(tournamentManager: tournamentManager))` (line 60), add:

```swift
                    .environment(cashSessionManager)
```

**Step 3: Commit**

```bash
git add StackTrackerPro/App/StackTrackerProApp.swift
git commit -m "feat: wire CashSessionManager into app environment"
```

---

### Task 6: Create CashSessionSetupView

**Files:**
- Create: `StackTrackerPro/Views/CashGame/CashSessionSetupView.swift`

**Step 1: Create the directory and file**

```swift
import SwiftUI
import SwiftData

struct CashSessionSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(CashSessionManager.self) private var cashSessionManager

    @AppStorage(SettingsKeys.defaultGameType) private var defaultGameType = GameType.nlh.rawValue

    @State private var stakes = ""
    @State private var selectedGameType: GameType = .nlh
    @State private var venueName = ""
    @State private var buyInText = ""

    private let stakesPresets = ["1/2", "1/3", "2/5", "5/10"]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.backgroundPrimary.ignoresSafeArea()

                Form {
                    gameInfoSection
                    venueSection
                    buyInSection
                    startButton
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("New Cash Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
            }
            .onAppear {
                selectedGameType = GameType(rawValue: defaultGameType) ?? .nlh
            }
        }
    }

    // MARK: - Game Info

    private var gameInfoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Stakes")
                    .foregroundColor(.textSecondary)

                HStack(spacing: 8) {
                    ForEach(stakesPresets, id: \.self) { preset in
                        Button {
                            stakes = preset
                        } label: {
                            Text(preset)
                                .font(PokerTypography.chipLabel)
                                .foregroundColor(stakes == preset ? .backgroundPrimary : .goldAccent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(stakes == preset ? Color.goldAccent : Color.goldAccent.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                }

                TextField("Custom (e.g. 25/50)", text: $stakes)
                    .foregroundColor(.textPrimary)
                    .textFieldStyle(.roundedBorder)
            }

            Picker("Game Type", selection: $selectedGameType) {
                ForEach(GameType.allCases, id: \.self) { type in
                    Text(type.label).tag(type)
                }
            }
            .tint(.goldAccent)
        } header: {
            Text("GAME INFO")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
        }
        .listRowBackground(Color.cardSurface)
    }

    // MARK: - Venue

    private var venueSection: some View {
        Section {
            TextField("Venue Name", text: $venueName)
                .foregroundColor(.textPrimary)
        } header: {
            Text("VENUE")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
        }
        .listRowBackground(Color.cardSurface)
    }

    // MARK: - Buy-in

    private var buyInSection: some View {
        Section {
            HStack {
                Text("$")
                    .foregroundColor(.textSecondary)
                TextField("Buy-in Amount", text: $buyInText)
                    .keyboardType(.numberPad)
                    .foregroundColor(.textPrimary)
            }
        } header: {
            Text("BUY-IN")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
        }
        .listRowBackground(Color.cardSurface)
    }

    // MARK: - Start Button

    private var startButton: some View {
        Section {
            Button {
                createAndStartSession()
            } label: {
                Text("Start Session")
            }
            .buttonStyle(PokerButtonStyle(isEnabled: isValid))
            .disabled(!isValid)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        }
    }

    private var isValid: Bool {
        !stakes.trimmingCharacters(in: .whitespaces).isEmpty && (Int(buyInText) ?? 0) > 0
    }

    private func createAndStartSession() {
        guard let buyIn = Int(buyInText), buyIn > 0 else { return }
        let session = CashSession(
            stakes: stakes,
            gameType: selectedGameType,
            buyInTotal: buyIn,
            venueName: venueName.isEmpty ? nil : venueName
        )
        modelContext.insert(session)
        cashSessionManager.startSession(session)
        dismiss()
    }
}
```

**Step 2: Commit**

```bash
git add StackTrackerPro/Views/CashGame/CashSessionSetupView.swift
git commit -m "feat: add CashSessionSetupView for cash game setup"
```

---

### Task 7: Create CashSessionStatusBar and EndCashSessionSheet

**Files:**
- Create: `StackTrackerPro/Views/CashGame/CashSessionStatusBar.swift`
- Create: `StackTrackerPro/Views/CashGame/EndCashSessionSheet.swift`

**Step 1: Create CashSessionStatusBar.swift**

```swift
import SwiftUI

struct CashSessionStatusBar: View {
    let session: CashSession

    var body: some View {
        HStack(spacing: 12) {
            // Session info
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)

                if let venue = session.venueName {
                    Text(venue)
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)
                }
            }

            Spacer()

            // Live timer
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                let elapsed = context.date.timeIntervalSince(session.startTime)
                let hours = Int(elapsed) / 3600
                let minutes = (Int(elapsed) % 3600) / 60
                Text(String(format: "%d:%02d", hours, minutes))
                    .font(PokerTypography.statValue)
                    .foregroundColor(.goldAccent)
                    .monospacedDigit()
            }

            // Live P/L
            if let latest = session.latestStack {
                let currentPL = latest.chipCount - session.buyInTotal
                Text(currentPL >= 0 ? "+$\(currentPL)" : "-$\(abs(currentPL))")
                    .font(PokerTypography.statValue)
                    .foregroundColor(currentPL >= 0 ? .mZoneGreen : .chipRed)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.backgroundSecondary)
    }
}
```

**Step 2: Create EndCashSessionSheet.swift**

```swift
import SwiftUI

struct EndCashSessionSheet: View {
    @Environment(CashSessionManager.self) private var cashSessionManager
    @Environment(\.dismiss) private var dismiss

    let session: CashSession

    @State private var cashOutText = ""

    // MARK: - Computed

    private var parsedCashOut: Int? {
        Int(cashOutText)
    }

    private var computedProfit: Int? {
        guard let cashOut = parsedCashOut else { return nil }
        return cashOut - session.buyInTotal
    }

    private var elapsedInterval: TimeInterval {
        Date.now.timeIntervalSince(session.startTime)
    }

    private var liveDuration: String {
        let elapsed = elapsedInterval
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private var computedHourlyRate: Double? {
        guard let profit = computedProfit, elapsedInterval > 0 else { return nil }
        return Double(profit) / (elapsedInterval / 3600)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cashOutSection
                    sessionSummarySection
                    endButton
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("End Cash Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
            }
        }
    }

    // MARK: - Sections

    private var cashOutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CASH OUT")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)

            HStack {
                Text("$")
                    .foregroundColor(.textSecondary)
                    .font(.title2)
                TextField("Cash-out amount", text: $cashOutText)
                    .keyboardType(.numberPad)
                    .foregroundColor(.textPrimary)
                    .font(.title2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var sessionSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SESSION SUMMARY")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)

            VStack(spacing: 0) {
                summaryRow("Stakes", value: session.stakes)

                Divider().background(Color.textSecondary.opacity(0.2))
                summaryRow("Duration", value: liveDuration)

                Divider().background(Color.textSecondary.opacity(0.2))
                summaryRow("Total Buy-in", value: "$\(session.buyInTotal)")

                if let profit = computedProfit {
                    Divider().background(Color.textSecondary.opacity(0.2))
                    summaryRow(
                        "Profit / Loss",
                        value: profit >= 0 ? "+$\(profit)" : "-$\(abs(profit))",
                        valueColor: profit >= 0 ? .mZoneGreen : .chipRed
                    )
                }

                if let rate = computedHourlyRate {
                    Divider().background(Color.textSecondary.opacity(0.2))
                    let formatted = String(format: "$%.0f/hr", abs(rate))
                    summaryRow(
                        "Hourly Rate",
                        value: rate >= 0 ? "+\(formatted)" : "-\(formatted)",
                        valueColor: rate >= 0 ? .mZoneGreen : .chipRed
                    )
                }
            }
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var endButton: some View {
        Button {
            endSession()
        } label: {
            Text("End Session")
                .font(.headline.weight(.semibold))
                .foregroundColor(.backgroundPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(parsedCashOut != nil ? Color.goldAccent : Color.goldAccent.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(parsedCashOut == nil)
        .padding(.top, 8)
    }

    private func summaryRow(_ label: String, value: String, valueColor: Color = .textPrimary) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.textSecondary)
            Spacer()
            Text(value)
                .foregroundColor(valueColor)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func endSession() {
        guard let cashOut = parsedCashOut else { return }
        cashSessionManager.completeSession(cashOut: cashOut)
        dismiss()
    }
}
```

**Step 3: Commit**

```bash
git add StackTrackerPro/Views/CashGame/CashSessionStatusBar.swift StackTrackerPro/Views/CashGame/EndCashSessionSheet.swift
git commit -m "feat: add CashSessionStatusBar and EndCashSessionSheet"
```

---

### Task 8: Create CashActiveSessionView

**Files:**
- Create: `StackTrackerPro/Views/CashGame/CashActiveSessionView.swift`

**Step 1: Create CashActiveSessionView.swift**

This mirrors `ActiveSessionView` but tailored for cash games — 4 panes instead of 8:

```swift
import SwiftUI

struct CashActiveSessionView: View {
    @Environment(CashSessionManager.self) private var cashSessionManager
    @Environment(ChatManager.self) private var chatManager

    @AppStorage(SettingsKeys.keepScreenAwake) private var keepScreenAwake = true

    @Bindable var session: CashSession
    @State private var messageText = ""
    @State private var selectedPage = 0
    @State private var showEndSession = false

    var body: some View {
        VStack(spacing: 0) {
            CashSessionStatusBar(session: session)

            // Page indicator
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(index == selectedPage ? Color.goldAccent : Color.textSecondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .animation(.spring(response: 0.3), value: selectedPage)
                }
            }
            .padding(.vertical, 8)

            // Swipeable pager
            TabView(selection: $selectedPage) {
                // Stack/dollar graph
                CashStackGraphView(session: session)
                    .tag(0)

                // Session stats
                CashSessionStatsView(session: session)
                    .tag(1)

                // Hand notes
                HandNotesPane(cashSession: session)
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Cash game quick actions + chat input
            CashChatInputView(
                text: $messageText,
                onSend: sendMessage,
                onAddOn: { showAddOnPrompt() },
                onCashOut: { showEndSession = true },
                onStackUpdate: {},
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
                        } label: {
                            Label("Pause", systemImage: "pause.circle")
                        }
                    } else if session.status == .paused {
                        Button {
                            cashSessionManager.resumeSession()
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
                        showEndSession = true
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
            } else if session.status == .paused {
                cashSessionManager.resumeSession()
            }
        }
        .sheet(isPresented: $showEndSession) {
            EndCashSessionSheet(session: session)
        }
        .sheet(isPresented: Bindable(cashSessionManager).showSessionRecap) {
            if let recapSession = cashSessionManager.completedSessionForRecap {
                CashSessionRecapSheet(session: recapSession) {
                    cashSessionManager.dismissRecap()
                }
            }
        }
    }

    // MARK: - Actions

    @State private var showAddOnAlert = false
    @State private var addOnText = ""

    private func sendMessage() {
        let text = messageText
        messageText = ""
        // Parse dollar amounts for cash game
        if let amount = parseDollarAmount(text) {
            cashSessionManager.updateStack(dollarAmount: amount)
        } else {
            // Treat as hand note
            cashSessionManager.recordHandNote(text)
        }
        HapticFeedback.impact(.light)
    }

    private func showAddOnPrompt() {
        showAddOnAlert = true
    }

    private func parseDollarAmount(_ text: String) -> Int? {
        let cleaned = text
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Int(cleaned)
    }
}
```

**Step 2: Create supporting views**

Create `StackTrackerPro/Views/CashGame/CashStackGraphView.swift`:

```swift
import SwiftUI
import Charts

struct CashStackGraphView: View {
    let session: CashSession

    private var entries: [StackEntry] {
        session.sortedStackEntries
    }

    private var dataPoints: [(index: Int, amount: Int)] {
        entries.enumerated().map { (index: $0.offset, amount: $0.element.chipCount) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("STACK PROGRESSION")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.textSecondary)
                .padding(.horizontal, 16)

            if dataPoints.count >= 2 {
                Chart {
                    ForEach(dataPoints, id: \.index) { point in
                        AreaMark(
                            x: .value("Update", point.index),
                            y: .value("Stack", point.amount)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.goldAccent.opacity(0.3), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Update", point.index),
                            y: .value("Stack", point.amount)
                        )
                        .foregroundStyle(Color.goldAccent)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .interpolationMethod(.catmullRom)
                    }

                    // Buy-in reference line
                    RuleMark(y: .value("Buy-in", session.buyInTotal))
                        .foregroundStyle(Color.textSecondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
                }
                .frame(height: 250)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisValueLabel {
                            if let amount = value.as(Int.self) {
                                Text("$\(amount)")
                                    .font(.caption2)
                                    .foregroundColor(.textSecondary)
                            }
                        }
                        AxisGridLine()
                            .foregroundStyle(Color.borderSubtle)
                    }
                }
                .chartXAxis(.hidden)
                .chartPlotStyle { plot in
                    plot
                        .background(Color.cardSurface.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding(.horizontal, 16)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.cardSurface.opacity(0.5))
                        .frame(height: 250)

                    VStack(spacing: 8) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.title2)
                            .foregroundColor(.textSecondary.opacity(0.5))
                        Text("Update your stack to see the graph")
                            .font(PokerTypography.chatCaption)
                            .foregroundColor(.textSecondary)
                    }
                }
                .padding(.horizontal, 16)
            }

            Spacer()
        }
        .padding(.top, 16)
    }
}
```

Create `StackTrackerPro/Views/CashGame/CashSessionStatsView.swift`:

```swift
import SwiftUI

struct CashSessionStatsView: View {
    let session: CashSession

    private var currentPL: Int {
        guard let latest = session.latestStack else { return 0 }
        return latest.chipCount - session.buyInTotal
    }

    private var liveHourlyRate: Double {
        let elapsed = Date.now.timeIntervalSince(session.startTime)
        guard elapsed > 0 else { return 0 }
        return Double(currentPL) / (elapsed / 3600)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Hero P/L
                VStack(spacing: 4) {
                    Text(currentPL >= 0 ? "+$\(currentPL)" : "-$\(abs(currentPL))")
                        .font(PokerTypography.heroStat)
                        .foregroundColor(currentPL >= 0 ? .mZoneGreen : .chipRed)

                    Text("Current P/L")
                        .font(PokerTypography.sectionHeader)
                        .foregroundColor(.textSecondary)
                }
                .padding(.vertical, 8)

                // Stats grid
                let columns = [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ]

                LazyVGrid(columns: columns, spacing: 12) {
                    statCard(
                        label: "Duration",
                        value: session.durationFormatted,
                        color: .goldAccent
                    )
                    statCard(
                        label: "Hourly Rate",
                        value: String(format: "$%.0f/hr", liveHourlyRate),
                        color: liveHourlyRate >= 0 ? .mZoneGreen : .chipRed
                    )
                    statCard(
                        label: "Total Buy-in",
                        value: "$\(session.buyInTotal)",
                        color: .goldAccent
                    )
                    statCard(
                        label: "Current Stack",
                        value: "$\(session.latestStack?.chipCount ?? session.buyInTotal)",
                        color: .goldAccent
                    )
                    statCard(
                        label: "Stakes",
                        value: session.stakes,
                        color: .goldAccent
                    )
                    statCard(
                        label: "Hand Notes",
                        value: "\(session.handNotes?.count ?? 0)",
                        color: .goldAccent
                    )
                }
            }
            .padding(16)
        }
    }

    private func statCard(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(PokerTypography.statValue)
                .foregroundColor(color)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(PokerTypography.chatCaption)
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .pokerCard()
    }
}
```

Create `StackTrackerPro/Views/CashGame/CashChatInputView.swift`:

```swift
import SwiftUI

struct CashChatInputView: View {
    @Binding var text: String
    let onSend: () -> Void
    let onAddOn: () -> Void
    let onCashOut: () -> Void
    let onStackUpdate: () -> Void
    let onHandNote: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            // Quick action chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    quickActionButton(label: "Add-on", icon: "plus.circle") { onAddOn() }
                    quickActionButton(label: "Cash Out", icon: "banknote") { onCashOut() }
                    quickActionButton(label: "Hand Note", icon: "note.text") { onHandNote() }
                }
                .padding(.horizontal, 16)
            }

            // Text input
            HStack(spacing: 10) {
                TextField("Update your stack ($)...", text: $text)
                    .font(PokerTypography.chatBody)
                    .foregroundColor(.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.borderSubtle, lineWidth: 1)
                    )
                    .focused($isFocused)
                    .onSubmit { sendIfReady() }

                Button {
                    sendIfReady()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(canSend ? .goldAccent : .goldAccent.opacity(0.3))
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .background(Color.backgroundSecondary)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendIfReady() {
        guard canSend else { return }
        onSend()
    }

    private func quickActionButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
            }
            .quickChip()
        }
    }
}
```

Create `StackTrackerPro/Views/CashGame/CashSessionRecapSheet.swift`:

```swift
import SwiftUI

struct CashSessionRecapSheet: View {
    let session: CashSession
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Hero P/L
                    VStack(spacing: 4) {
                        if let profit = session.profit {
                            Text(profit >= 0 ? "+$\(profit)" : "-$\(abs(profit))")
                                .font(PokerTypography.heroStat)
                                .foregroundColor(profit >= 0 ? .mZoneGreen : .chipRed)
                        }

                        Text(session.displayName)
                            .font(.title3.weight(.semibold))
                            .foregroundColor(.textPrimary)

                        if let venue = session.venueName {
                            Text(venue)
                                .font(PokerTypography.chatBody)
                                .foregroundColor(.textSecondary)
                        }
                    }
                    .padding(.top, 20)

                    // Stats
                    VStack(spacing: 0) {
                        recapRow("Duration", value: session.durationFormatted)
                        Divider().background(Color.textSecondary.opacity(0.2))
                        recapRow("Buy-in", value: "$\(session.buyInTotal)")
                        Divider().background(Color.textSecondary.opacity(0.2))
                        recapRow("Cash Out", value: "$\(session.cashOut ?? 0)")

                        if let rate = session.hourlyRate {
                            Divider().background(Color.textSecondary.opacity(0.2))
                            let formatted = String(format: "$%.0f/hr", abs(rate))
                            recapRow(
                                "Hourly Rate",
                                value: rate >= 0 ? "+\(formatted)" : "-\(formatted)",
                                valueColor: rate >= 0 ? .mZoneGreen : .chipRed
                            )
                        }
                    }
                    .background(Color.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                }
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Session Complete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                        .foregroundColor(.goldAccent)
                }
            }
        }
    }

    private func recapRow(_ label: String, value: String, valueColor: Color = .textPrimary) -> some View {
        HStack {
            Text(label).foregroundColor(.textSecondary)
            Spacer()
            Text(value).foregroundColor(valueColor).fontWeight(.medium)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
```

**Step 3: Commit**

```bash
git add StackTrackerPro/Views/CashGame/
git commit -m "feat: add CashActiveSessionView with stats, graph, input, and recap"
```

---

### Task 9: Update HandNotesPane to support CashSession

**Files:**
- Modify: `StackTrackerPro/Views/Session/HandNotesPane.swift`

**Step 1: Read the current HandNotesPane implementation**

Read the file first, then add an optional `cashSession` parameter. The view should work with either a tournament or a cash session.

Add an optional `cashSession: CashSession?` init parameter. When `cashSession` is non-nil, use its hand notes and the `CashSessionManager` for CRUD. When tournament is provided, use existing behavior.

The key changes:
- Add `var cashSession: CashSession? = nil` property
- Compute `handNotes` from whichever session is provided
- Route add/update/delete through appropriate manager

**Step 2: Commit**

```bash
git add StackTrackerPro/Views/Session/HandNotesPane.swift
git commit -m "feat: update HandNotesPane to support both tournament and cash sessions"
```

---

### Task 10: Create CashSessionListView and update Play tab

**Files:**
- Create: `StackTrackerPro/Views/CashGame/CashSessionListView.swift`
- Modify: `StackTrackerPro/App/ContentView.swift`

**Step 1: Create CashSessionListView.swift**

```swift
import SwiftUI
import SwiftData

struct CashSessionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(CashSessionManager.self) private var cashSessionManager
    @Query(filter: #Predicate<CashSession> { $0.statusRaw != "completed" },
           sort: \CashSession.startTime, order: .reverse)
    private var sessions: [CashSession]

    @State private var showingSetup = false

    var body: some View {
        ZStack {
            Color.backgroundPrimary.ignoresSafeArea()

            if sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSetup = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.goldAccent)
                }
            }
        }
        .sheet(isPresented: $showingSetup) {
            CashSessionSetupView()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "dollarsign.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.goldAccent.opacity(0.5))

            Text("No Cash Sessions")
                .font(.title2.weight(.semibold))
                .foregroundColor(.textPrimary)

            Text("Tap + to start tracking a cash game")
                .font(PokerTypography.chatBody)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                showingSetup = true
            } label: {
                Text("New Cash Session")
            }
            .buttonStyle(PokerButtonStyle(isEnabled: true))
            .padding(.horizontal, 40)
            .padding(.top, 8)
        }
        .padding()
    }

    private var sessionList: some View {
        List {
            ForEach(sessions, id: \.persistentModelID) { session in
                NavigationLink {
                    CashActiveSessionView(session: session)
                } label: {
                    sessionRow(session)
                }
                .listRowBackground(Color.cardSurface)
            }
            .onDelete(perform: deleteSessions)
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
    }

    private func sessionRow(_ session: CashSession) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayName)
                    .font(.headline)
                    .foregroundColor(.textPrimary)

                if let venue = session.venueName {
                    Text(venue)
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)
                }

                Text(session.startTime.formatted(date: .abbreviated, time: .shortened))
                    .font(PokerTypography.chatCaption)
                    .foregroundColor(.textSecondary)
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: session.status.icon)
                    .font(.caption2)
                Text(session.status.label)
                    .font(PokerTypography.chipLabel)
            }
            .foregroundColor(session.status.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(session.status.color.opacity(0.15))
            .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            let session = sessions[index]
            if cashSessionManager.activeSession?.persistentModelID == session.persistentModelID {
                cashSessionManager.activeSession = nil
            }
            modelContext.delete(session)
        }
    }
}
```

**Step 2: Update ContentView.swift with segmented Play tab**

Replace the current ContentView body:

```swift
struct ContentView: View {
    @Environment(TournamentManager.self) private var tournamentManager

    @State private var selectedPlayMode: PlayMode = .tournaments

    enum PlayMode: String, CaseIterable {
        case tournaments = "Tournaments"
        case cashGames = "Cash Games"
    }

    var body: some View {
        TabView {
            Tab("Play", systemImage: "suit.spade.fill") {
                NavigationStack {
                    VStack(spacing: 0) {
                        Picker("Mode", selection: $selectedPlayMode) {
                            ForEach(PlayMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                        ZStack {
                            if selectedPlayMode == .tournaments {
                                TournamentListView()
                            } else {
                                CashSessionListView()
                            }
                        }
                    }
                    .background(Color.backgroundPrimary)
                    .navigationTitle("Stack Tracker Pro")
                }
            }

            Tab("Results", systemImage: "chart.line.uptrend.xyaxis") {
                ResultsView()
            }

            Tab("Settings", systemImage: "gearshape.fill") {
                SettingsView()
            }
        }
        .tint(.goldAccent)
        .preferredColorScheme(.dark)
    }
}
```

Note: `TournamentListView` will need its `NavigationStack` removed since the parent now provides one. The toolbar items should remain. Read the file and adjust accordingly.

**Step 3: Commit**

```bash
git add StackTrackerPro/Views/CashGame/CashSessionListView.swift StackTrackerPro/App/ContentView.swift
git commit -m "feat: add CashSessionListView and segmented Play tab"
```

---

### Task 11: Create unified ResultsView

**Files:**
- Create: `StackTrackerPro/Views/Results/ResultsView.swift`

**Step 1: Create ResultsView.swift**

This replaces `TournamentHistoryView` as the "Results" tab. It queries both completed tournaments and completed cash sessions, merges them, and displays a unified list with filter chips.

```swift
import SwiftUI
import SwiftData
import Charts

enum ResultsFilter: String, CaseIterable {
    case all = "All"
    case cash = "Cash"
    case tournaments = "Tournaments"
}

struct ResultsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(filter: #Predicate<Tournament> { $0.statusRaw == "completed" },
           sort: \Tournament.endDate, order: .reverse)
    private var completedTournaments: [Tournament]

    @Query(filter: #Predicate<CashSession> { $0.statusRaw == "completed" },
           sort: \CashSession.endTime, order: .reverse)
    private var completedCashSessions: [CashSession]

    @State private var filter: ResultsFilter = .all
    @State private var viewMode: ViewMode = .list

    enum ViewMode: String, CaseIterable {
        case list = "List"
        case analytics = "Analytics"
    }

    // Unified session list
    private var allSessions: [(date: Date, profit: Int, type: ResultsFilter, label: String, venue: String?, duration: String, detail: String)] {
        var results: [(date: Date, profit: Int, type: ResultsFilter, label: String, venue: String?, duration: String, detail: String)] = []

        for t in completedTournaments {
            guard let profit = t.profit, let endDate = t.endDate else { continue }
            let detail: String
            if let pos = t.finishPosition {
                detail = "\(ordinal(pos))" + (t.fieldSize > 0 ? " of \(t.fieldSize)" : "") + " · $\(t.totalInvestment) buy-in"
            } else {
                detail = "$\(t.totalInvestment) buy-in"
            }
            results.append((
                date: endDate,
                profit: profit,
                type: .tournaments,
                label: t.name,
                venue: t.venueName,
                duration: t.durationFormatted,
                detail: detail
            ))
        }

        for s in completedCashSessions {
            guard let profit = s.profit, let endTime = s.endTime else { continue }
            results.append((
                date: endTime,
                profit: profit,
                type: .cash,
                label: s.displayName,
                venue: s.venueName,
                duration: s.durationFormatted,
                detail: "$\(s.buyInTotal) buy-in"
            ))
        }

        return results
            .filter { filter == .all || $0.type == filter }
            .sorted { $0.date > $1.date }
    }

    private var cumulativePLData: [(index: Int, cumulative: Int, date: Date)] {
        let sorted = allSessions.sorted { $0.date < $1.date }
        var running = 0
        return sorted.enumerated().map { i, s in
            running += s.profit
            return (index: i + 1, cumulative: running, date: s.date)
        }
    }

    // Aggregate stats
    private var totalProfit: Int { allSessions.map(\.profit).reduce(0, +) }
    private var winRate: Double {
        guard !allSessions.isEmpty else { return 0 }
        let wins = allSessions.filter { $0.profit > 0 }.count
        return Double(wins) / Double(allSessions.count) * 100
    }
    private var sessionCount: Int { allSessions.count }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !allSessions.isEmpty || !completedTournaments.isEmpty || !completedCashSessions.isEmpty {
                    // Filter chips
                    HStack(spacing: 8) {
                        ForEach(ResultsFilter.allCases, id: \.self) { f in
                            Button {
                                withAnimation { filter = f }
                            } label: {
                                Text(f.rawValue)
                                    .font(PokerTypography.chipLabel)
                                    .foregroundColor(filter == f ? .backgroundPrimary : .goldAccent)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(filter == f ? Color.goldAccent : Color.goldAccent.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }

                        Spacer()

                        Picker("View", selection: $viewMode) {
                            ForEach(ViewMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                ZStack {
                    Color.backgroundPrimary.ignoresSafeArea()

                    if allSessions.isEmpty && completedTournaments.isEmpty && completedCashSessions.isEmpty {
                        emptyState
                    } else if viewMode == .analytics {
                        ResultsAnalyticsView(
                            filter: filter,
                            tournaments: completedTournaments,
                            cashSessions: completedCashSessions
                        )
                    } else {
                        resultsList
                    }
                }
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Results")
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 60))
                .foregroundColor(.goldAccent.opacity(0.5))

            Text("No Results Yet")
                .font(.title2.weight(.semibold))
                .foregroundColor(.textPrimary)

            Text("Completed sessions will appear here\nwith results and analytics")
                .font(PokerTypography.chatBody)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    // MARK: - Results List

    private var resultsList: some View {
        List {
            // Aggregate stats header
            Section {
                aggregateStatsHeader
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
            }

            // P/L chart
            if cumulativePLData.count >= 2 {
                Section {
                    cumulativePLChart
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                }
            }

            // Session rows
            Section {
                ForEach(Array(allSessions.enumerated()), id: \.offset) { _, session in
                    sessionRow(session)
                        .listRowBackground(Color.cardSurface)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
    }

    // MARK: - Aggregate Stats

    private var aggregateStatsHeader: some View {
        HStack(spacing: 0) {
            statColumn(value: "\(sessionCount)", label: "Sessions")
            Divider().frame(height: 32).overlay(Color.borderSubtle)
            statColumn(value: String(format: "%.0f%%", winRate), label: "Win Rate")
            Divider().frame(height: 32).overlay(Color.borderSubtle)
            statColumn(
                value: formatCurrency(totalProfit),
                label: "Profit",
                color: totalProfit >= 0 ? .mZoneGreen : .chipRed
            )
        }
        .padding(.vertical, 12)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.borderSubtle, lineWidth: 0.5)
        )
    }

    // MARK: - P/L Chart

    private var cumulativePLChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CUMULATIVE P/L")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.textSecondary)

            Chart {
                ForEach(cumulativePLData, id: \.index) { point in
                    AreaMark(
                        x: .value("Session", point.index),
                        y: .value("P/L", point.cumulative)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.goldAccent.opacity(0.3), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Session", point.index),
                        y: .value("P/L", point.cumulative)
                    )
                    .foregroundStyle(Color.goldAccent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .interpolationMethod(.catmullRom)
                }

                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(Color.textSecondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
            }
            .frame(height: 180)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let amount = value.as(Int.self) {
                            Text(formatCurrencyShort(amount))
                                .font(.caption2)
                                .foregroundColor(.textSecondary)
                        }
                    }
                    AxisGridLine().foregroundStyle(Color.borderSubtle)
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let session = value.as(Int.self) {
                            Text("#\(session)")
                                .font(.caption2)
                                .foregroundColor(.textSecondary)
                        }
                    }
                }
            }
            .chartPlotStyle { plot in
                plot
                    .background(Color.cardSurface.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .pokerCard()
    }

    // MARK: - Session Row

    private func sessionRow(_ session: (date: Date, profit: Int, type: ResultsFilter, label: String, venue: String?, duration: String, detail: String)) -> some View {
        HStack(spacing: 12) {
            // Type icon
            Image(systemName: session.type == .cash ? "dollarsign.circle.fill" : "trophy.fill")
                .foregroundColor(session.type == .cash ? .chipBlue : .goldAccent)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.label)
                    .font(.headline)
                    .foregroundColor(.textPrimary)

                HStack(spacing: 8) {
                    if let venue = session.venue {
                        Text(venue)
                            .font(PokerTypography.chipLabel)
                            .foregroundColor(.textSecondary)
                    }
                }

                Text(session.date.formatted(date: .abbreviated, time: .omitted))
                    .font(PokerTypography.chatCaption)
                    .foregroundColor(.textSecondary)

                HStack(spacing: 4) {
                    Text(session.duration)
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)
                    Text("·")
                        .foregroundColor(.textSecondary)
                    Text(session.detail)
                        .font(PokerTypography.chatCaption)
                        .foregroundColor(.textSecondary)
                }
            }

            Spacer()

            // P/L badge
            let isPositive = session.profit >= 0
            Text(isPositive ? "+\(formatCurrency(session.profit))" : formatCurrency(session.profit))
                .font(PokerTypography.chipLabel)
                .foregroundColor(isPositive ? .mZoneGreen : .chipRed)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((isPositive ? Color.mZoneGreen : Color.chipRed).opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func statColumn(value: String, label: String, color: Color = .textPrimary) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(PokerTypography.statValue)
                .foregroundColor(color)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(PokerTypography.chatCaption)
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatCurrency(_ amount: Int) -> String {
        amount < 0 ? "-$\(abs(amount))" : "$\(amount)"
    }

    private func formatCurrencyShort(_ amount: Int) -> String {
        let a = abs(amount)
        let sign = amount < 0 ? "-" : ""
        if a >= 1000 { return "\(sign)$\(a / 1000)k" }
        return "\(sign)$\(a)"
    }

    private func ordinal(_ n: Int) -> String {
        let tens = (n / 10) % 10
        if tens == 1 { return "\(n)th" }
        switch n % 10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }
}
```

**Step 2: Commit**

```bash
git add StackTrackerPro/Views/Results/ResultsView.swift
git commit -m "feat: add unified ResultsView with filters and cumulative P/L graph"
```

---

### Task 12: Create ResultsAnalyticsView

**Files:**
- Create: `StackTrackerPro/Views/Results/ResultsAnalyticsView.swift`

**Step 1: Create ResultsAnalyticsView.swift**

This extends the existing `AnalyticsDashboardView` pattern but works with both session types and respects the active filter. Rather than duplicating all the analytics code, it delegates to `AnalyticsDashboardView` for tournament-only mode and provides new combined/cash analytics.

```swift
import SwiftUI
import Charts

struct ResultsAnalyticsView: View {
    let filter: ResultsFilter
    let tournaments: [Tournament]
    let cashSessions: [CashSession]

    var body: some View {
        switch filter {
        case .tournaments:
            AnalyticsDashboardView(tournaments: tournaments)
        case .cash:
            CashAnalyticsView(sessions: cashSessions)
        case .all:
            CombinedAnalyticsView(tournaments: tournaments, cashSessions: cashSessions)
        }
    }
}

// MARK: - Cash Analytics

struct CashAnalyticsView: View {
    let sessions: [CashSession]

    private var totalProfit: Int {
        sessions.compactMap(\.profit).reduce(0, +)
    }

    private var winRate: Double {
        guard !sessions.isEmpty else { return 0 }
        let wins = sessions.filter { ($0.profit ?? 0) > 0 }.count
        return Double(wins) / Double(sessions.count) * 100
    }

    private var totalHours: Double {
        sessions.compactMap(\.duration).reduce(0, +) / 3600
    }

    private var avgHourlyRate: Double {
        let rates = sessions.compactMap(\.hourlyRate)
        guard !rates.isEmpty else { return 0 }
        return rates.reduce(0, +) / Double(rates.count)
    }

    private var biggestWin: Int {
        sessions.compactMap(\.profit).max() ?? 0
    }

    private var biggestLoss: Int {
        sessions.compactMap(\.profit).min() ?? 0
    }

    private var stakesStats: [(stakes: String, sessions: Int, profit: Int, winRate: Double)] {
        let grouped = Dictionary(grouping: sessions) { $0.stakes }
        return grouped.map { stakes, group in
            let profit = group.compactMap(\.profit).reduce(0, +)
            let wins = group.filter { ($0.profit ?? 0) > 0 }.count
            let wr = group.isEmpty ? 0 : Double(wins) / Double(group.count) * 100
            return (stakes: stakes, sessions: group.count, profit: profit, winRate: wr)
        }
        .sorted { $0.profit > $1.profit }
    }

    var body: some View {
        if sessions.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.goldAccent.opacity(0.5))
                Text("No Cash Sessions")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.textPrimary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 16) {
                    // Summary
                    let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
                    LazyVGrid(columns: columns, spacing: 12) {
                        summaryCard(title: "Total Profit", value: formatCurrency(totalProfit), color: totalProfit >= 0 ? .mZoneGreen : .chipRed)
                        summaryCard(title: "Win Rate", value: String(format: "%.0f%%", winRate), color: .goldAccent)
                        summaryCard(title: "Avg Hourly", value: String(format: "$%.0f/hr", avgHourlyRate), color: avgHourlyRate >= 0 ? .mZoneGreen : .chipRed)
                        summaryCard(title: "Hours Played", value: String(format: "%.1f", totalHours), color: .goldAccent)
                    }

                    // By stakes
                    if !stakesStats.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("BY STAKES")
                                .font(PokerTypography.sectionHeader)
                                .foregroundColor(.textSecondary)
                            ForEach(stakesStats, id: \.stakes) { stat in
                                performanceRow(name: stat.stakes, profit: stat.profit, sessions: stat.sessions, winRate: stat.winRate)
                            }
                        }
                        .pokerCard()
                    }

                    // Key stats
                    VStack(alignment: .leading, spacing: 12) {
                        Text("KEY STATS")
                            .font(PokerTypography.sectionHeader)
                            .foregroundColor(.textSecondary)
                        LazyVGrid(columns: columns, spacing: 10) {
                            statCard(label: "Biggest Win", value: formatCurrency(biggestWin), color: .mZoneGreen)
                            statCard(label: "Biggest Loss", value: formatCurrency(biggestLoss), color: .chipRed)
                            statCard(label: "Total Sessions", value: "\(sessions.count)", color: .goldAccent)
                            statCard(label: "Avg Session", value: avgSessionDuration, color: .goldAccent)
                        }
                    }
                    .pokerCard()
                }
                .padding(16)
            }
        }
    }

    private var avgSessionDuration: String {
        let durations = sessions.compactMap(\.duration)
        guard !durations.isEmpty else { return "0m" }
        let avg = durations.reduce(0, +) / Double(durations.count)
        let hours = Int(avg) / 3600
        let minutes = (Int(avg) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private func summaryCard(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(value).font(PokerTypography.heroStat).foregroundColor(color).minimumScaleFactor(0.5).lineLimit(1)
            Text(title).font(PokerTypography.sectionHeader).foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .pokerCard()
    }

    private func performanceRow(name: String, profit: Int, sessions: Int, winRate: Double) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(PokerTypography.chatBody).foregroundColor(.textPrimary)
                HStack(spacing: 8) {
                    Text("\(sessions) session\(sessions == 1 ? "" : "s")").font(PokerTypography.chatCaption).foregroundColor(.textSecondary)
                    Text("\(String(format: "%.0f%%", winRate)) win rate").font(PokerTypography.chatCaption).foregroundColor(.textSecondary)
                }
            }
            Spacer()
            Text(formatCurrency(profit)).font(PokerTypography.statValue).foregroundColor(profit >= 0 ? .mZoneGreen : .chipRed)
        }
        .padding(10)
        .background(Color.cardSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statCard(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(PokerTypography.statValue).foregroundColor(color).minimumScaleFactor(0.7).lineLimit(1)
            Text(label).font(PokerTypography.chatCaption).foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color.cardSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func formatCurrency(_ amount: Int) -> String {
        amount < 0 ? "-$\(abs(amount))" : "$\(amount)"
    }
}

// MARK: - Combined Analytics

struct CombinedAnalyticsView: View {
    let tournaments: [Tournament]
    let cashSessions: [CashSession]

    private var tournamentProfit: Int { tournaments.compactMap(\.profit).reduce(0, +) }
    private var cashProfit: Int { cashSessions.compactMap(\.profit).reduce(0, +) }
    private var totalProfit: Int { tournamentProfit + cashProfit }
    private var totalSessions: Int { tournaments.count + cashSessions.count }
    private var totalWins: Int {
        tournaments.filter { ($0.profit ?? 0) > 0 }.count +
        cashSessions.filter { ($0.profit ?? 0) > 0 }.count
    }
    private var winRate: Double {
        guard totalSessions > 0 else { return 0 }
        return Double(totalWins) / Double(totalSessions) * 100
    }
    private var totalHours: Double {
        let tHours = tournaments.compactMap(\.duration).reduce(0, +) / 3600
        let cHours = cashSessions.compactMap(\.duration).reduce(0, +) / 3600
        return tHours + cHours
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
                LazyVGrid(columns: columns, spacing: 12) {
                    summaryCard(title: "Total Profit", value: formatCurrency(totalProfit), color: totalProfit >= 0 ? .mZoneGreen : .chipRed)
                    summaryCard(title: "Win Rate", value: String(format: "%.0f%%", winRate), color: .goldAccent)
                    summaryCard(title: "Total Sessions", value: "\(totalSessions)", color: .goldAccent)
                    summaryCard(title: "Hours Played", value: String(format: "%.1f", totalHours), color: .goldAccent)
                }

                // Breakdown by type
                VStack(alignment: .leading, spacing: 12) {
                    Text("BY TYPE")
                        .font(PokerTypography.sectionHeader)
                        .foregroundColor(.textSecondary)

                    typeRow(name: "Tournaments", sessions: tournaments.count, profit: tournamentProfit, icon: "trophy.fill", iconColor: .goldAccent)
                    typeRow(name: "Cash Games", sessions: cashSessions.count, profit: cashProfit, icon: "dollarsign.circle.fill", iconColor: .chipBlue)
                }
                .pokerCard()
            }
            .padding(16)
        }
    }

    private func summaryCard(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(value).font(PokerTypography.heroStat).foregroundColor(color).minimumScaleFactor(0.5).lineLimit(1)
            Text(title).font(PokerTypography.sectionHeader).foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .pokerCard()
    }

    private func typeRow(name: String, sessions: Int, profit: Int, icon: String, iconColor: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundColor(iconColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(PokerTypography.chatBody).foregroundColor(.textPrimary)
                Text("\(sessions) session\(sessions == 1 ? "" : "s")").font(PokerTypography.chatCaption).foregroundColor(.textSecondary)
            }
            Spacer()
            Text(formatCurrency(profit)).font(PokerTypography.statValue).foregroundColor(profit >= 0 ? .mZoneGreen : .chipRed)
        }
        .padding(10)
        .background(Color.cardSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func formatCurrency(_ amount: Int) -> String {
        amount < 0 ? "-$\(abs(amount))" : "$\(amount)"
    }
}
```

**Step 2: Commit**

```bash
git add StackTrackerPro/Views/Results/ResultsAnalyticsView.swift
git commit -m "feat: add ResultsAnalyticsView with cash, tournament, and combined analytics"
```

---

### Task 13: Create CSV Importer

**Files:**
- Create: `StackTrackerPro/Managers/CSVImporter.swift`

**Step 1: Create CSVImporter.swift**

```swift
import Foundation
import SwiftData

struct CSVImportResult {
    var cashSessionsCreated: Int = 0
    var tournamentsCreated: Int = 0
    var rowsSkipped: Int = 0
    var warnings: [String] = []
}

struct CSVImporter {

    /// Expected columns:
    /// Date, Format, Variant, Stakes, Location, Buy-in ($), Cash-out ($), Profit/Loss ($), Duration (hours), Hourly Rate ($/hr), Notes
    static func importCSV(from url: URL, into context: ModelContext) -> CSVImportResult {
        var result = CSVImportResult()

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            result.warnings.append("Could not read file")
            return result
        }

        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count > 1 else {
            result.warnings.append("File is empty or has no data rows")
            return result
        }

        // Skip header row
        for (lineIndex, line) in lines.dropFirst().enumerated() {
            let rowNum = lineIndex + 2 // 1-indexed, skip header
            let columns = parseCSVLine(line)

            guard columns.count >= 9 else {
                result.warnings.append("Row \(rowNum): not enough columns (\(columns.count)), skipping")
                result.rowsSkipped += 1
                continue
            }

            // Parse date
            guard let date = parseDate(columns[0]) else {
                result.warnings.append("Row \(rowNum): could not parse date '\(columns[0])', skipping")
                result.rowsSkipped += 1
                continue
            }

            let format = columns[1].trimmingCharacters(in: .whitespaces).lowercased()
            let variant = columns[2].trimmingCharacters(in: .whitespaces)
            let stakes = columns[3].trimmingCharacters(in: .whitespaces)
            let location = columns[4].trimmingCharacters(in: .whitespaces)
            let buyIn = parseCurrency(columns[5])
            let cashOut = parseCurrency(columns[6])
            let durationHours = Double(columns[8].trimmingCharacters(in: .whitespaces))
            let notes = columns.count > 10 ? columns[10].trimmingCharacters(in: .whitespaces) : nil

            guard let buyIn, buyIn > 0 else {
                result.warnings.append("Row \(rowNum): invalid buy-in '\(columns[5])', skipping")
                result.rowsSkipped += 1
                continue
            }

            let gameType = mapVariantToGameType(variant)
            let endTime = durationHours.map { date.addingTimeInterval($0 * 3600) }

            if format.contains("cash") {
                let session = CashSession(
                    stakes: stakes,
                    gameType: gameType,
                    buyInTotal: buyIn,
                    venueName: location.isEmpty ? nil : location,
                    date: date
                )
                session.cashOut = cashOut
                session.endTime = endTime
                session.statusRaw = SessionStatus.completed.rawValue
                session.isImported = true
                session.notes = (notes?.isEmpty ?? true) ? nil : notes
                context.insert(session)
                result.cashSessionsCreated += 1
            } else {
                // Tournament
                let tournament = Tournament(
                    name: "\(stakes) \(gameType.label)".trimmingCharacters(in: .whitespaces),
                    gameType: gameType,
                    buyIn: buyIn
                )
                tournament.payout = cashOut
                tournament.endDate = endTime
                tournament.statusRaw = TournamentStatus.completed.rawValue
                tournament.venueName = location.isEmpty ? nil : location
                tournament.startDate = date
                context.insert(tournament)
                result.tournamentsCreated += 1
            }
        }

        try? context.save()
        return result
    }

    // MARK: - Parsing Helpers

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current)
        return fields
    }

    private static func parseDate(_ string: String) -> Date? {
        let cleaned = string.trimmingCharacters(in: .whitespaces)
        let formats = ["MM/dd/yyyy", "yyyy-MM-dd", "M/d/yy", "M/d/yyyy", "MM-dd-yyyy"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) {
                return date
            }
        }
        return nil
    }

    private static func parseCurrency(_ string: String) -> Int? {
        let cleaned = string
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "(", with: "-")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespaces)

        if let intVal = Int(cleaned) {
            return intVal
        }
        if let doubleVal = Double(cleaned) {
            return Int(doubleVal)
        }
        return nil
    }

    private static func mapVariantToGameType(_ variant: String) -> GameType {
        let upper = variant.uppercased()
        if upper.contains("PLO") || upper.contains("OMAHA") {
            return .plo
        }
        if upper.contains("MIXED") {
            return .mixed
        }
        return .nlh
    }
}
```

**Step 2: Commit**

```bash
git add StackTrackerPro/Managers/CSVImporter.swift
git commit -m "feat: add CSVImporter for bulk session history import"
```

---

### Task 14: Add CSV Import UI to Settings

**Files:**
- Modify: `StackTrackerPro/Views/Settings/SettingsView.swift`

**Step 1: Add import state and UI**

Add these `@State` properties to SettingsView:

```swift
    @State private var showFileImporter = false
    @State private var importResult: CSVImportResult?
    @State private var showImportResult = false
```

Add a new section before the `dataSection` (around line 58):

```swift
                    importSection
```

Add the section view:

```swift
    // MARK: - Import

    private var importSection: some View {
        Section {
            Button {
                showFileImporter = true
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import Session History (CSV)")
                }
                .foregroundColor(.goldAccent)
            }
        } header: {
            Text("IMPORT")
                .font(PokerTypography.sectionHeader)
                .foregroundColor(.goldAccent)
        }
        .listRowBackground(Color.cardSurface)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                importResult = CSVImporter.importCSV(from: url, into: modelContext)
                showImportResult = true
            case .failure:
                break
            }
        }
        .alert("Import Complete", isPresented: $showImportResult) {
            Button("OK") {}
        } message: {
            if let r = importResult {
                Text("Imported \(r.cashSessionsCreated) cash session\(r.cashSessionsCreated == 1 ? "" : "s") and \(r.tournamentsCreated) tournament\(r.tournamentsCreated == 1 ? "" : "s").\(r.rowsSkipped > 0 ? " \(r.rowsSkipped) row\(r.rowsSkipped == 1 ? "" : "s") skipped." : "")")
            }
        }
    }
```

Also add `import UniformTypeIdentifiers` at the top of the file.

**Step 2: Update deleteAllData to also delete CashSessions**

In the `deleteAllData()` function, add after the tournament deletion loop:

```swift
        // Delete all cash sessions
        do {
            let cashSessions = try modelContext.fetch(FetchDescriptor<CashSession>())
            for session in cashSessions {
                modelContext.delete(session)
            }
        } catch {}
```

**Step 3: Commit**

```bash
git add StackTrackerPro/Views/Settings/SettingsView.swift
git commit -m "feat: add CSV import UI to Settings and update deleteAllData"
```

---

### Task 15: Fix TournamentListView navigation and final wiring

**Files:**
- Modify: `StackTrackerPro/Views/Tournament/TournamentListView.swift`

**Step 1: Remove NavigationStack from TournamentListView**

Since `ContentView` now wraps the Play tab in its own `NavigationStack`, remove the `NavigationStack` wrapper from `TournamentListView` (lines 13 and 38). Keep the inner content, toolbar, and sheet. The view should just return the `ZStack` with toolbar modifiers.

**Step 2: Verify build**

Build the Xcode project and fix any compilation errors.

**Step 3: Commit**

```bash
git add StackTrackerPro/Views/Tournament/TournamentListView.swift
git commit -m "fix: remove duplicate NavigationStack from TournamentListView"
```

---

### Task 16: Add default stakes to Settings

**Files:**
- Modify: `StackTrackerPro/Views/Settings/SettingsView.swift`
- Modify: `StackTrackerPro/Models/Enums.swift` (SettingsKeys is actually in SettingsView.swift)

**Step 1: Add settings key**

Add to `SettingsKeys`:

```swift
    static let defaultStakes = "settings.defaults.stakes"
```

**Step 2: Add AppStorage and UI**

Add to SettingsView properties:

```swift
    @AppStorage(SettingsKeys.defaultStakes) private var defaultStakes = "1/2"
```

Add to `sessionDefaultsSection`, after the Game Type picker:

```swift
            HStack {
                Text("Default Stakes")
                    .foregroundColor(.textSecondary)
                Spacer()
                TextField("1/2", text: $defaultStakes)
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.trailing)
            }
```

**Step 3: Commit**

```bash
git add StackTrackerPro/Views/Settings/SettingsView.swift
git commit -m "feat: add default stakes setting for cash games"
```

---

### Task 17: Build verification and cleanup

**Step 1: Build the project in Xcode**

Open the Xcode project and build. Fix any compilation errors:
- Missing imports
- Type mismatches
- Relationship inverse path issues
- Preview errors

**Step 2: Test the flow manually**

1. Launch app → Play tab shows segmented control (Tournaments | Cash Games)
2. Switch to Cash Games → Empty state with "New Cash Session" button
3. Tap + → CashSessionSetupView appears with stakes presets
4. Fill in and start → CashActiveSessionView with status bar, graph, stats
5. Enter stack amounts → Graph updates
6. End session → Recap sheet shows P/L
7. Go to Results tab → Session appears in list with correct icon and P/L
8. Toggle filter → Cash/Tournament/All filtering works
9. Analytics toggle → Combined/Cash/Tournament analytics render
10. Settings → Import CSV → Select file → Sessions imported
11. Results tab → Imported sessions appear

**Step 3: Final commit**

```bash
git add -A
git commit -m "fix: build fixes and cleanup for cash game feature"
```
