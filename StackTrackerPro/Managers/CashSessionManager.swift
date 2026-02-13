import Foundation
import SwiftData
import Observation

@MainActor @Observable
final class CashSessionManager {
    var activeSession: CashSession?
    var modelContext: ModelContext?

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
