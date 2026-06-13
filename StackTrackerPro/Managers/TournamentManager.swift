import Foundation
import SwiftData
import Observation
import UserNotifications
import os

@MainActor @Observable
final class TournamentManager {
    private static let logger = Logger(subsystem: "com.gyndok.stacktrackerpro", category: "TournamentManager")

    var activeTournament: Tournament? {
        didSet { restoreBreakState() }
    }
    var modelContext: ModelContext?

    // Session recap state
    var showSessionRecap = false
    var showEndTournament = false
    private(set) var completedTournamentForRecap: Tournament?

    // Break timer state (transient — derived from BreakEntry on restore)
    var isOnBreak = false
    var breakEndTime: Date?

    // Surfaced errors/state for the UI
    private(set) var lastSaveError: String?
    private(set) var notificationsDenied = false

    init() {}

    func setContext(_ context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - State Machine

    func startTournament(_ tournament: Tournament) {
        tournament.status = .active
        if tournament.actualStartDate == nil {
            tournament.actualStartDate = .now
        }
        activeTournament = tournament

        // Record initial stack entry
        if let blinds = tournament.currentBlinds {
            let entry = StackEntry(
                chipCount: tournament.startingChips,
                blindLevelNumber: blinds.levelNumber,
                currentSB: blinds.smallBlind,
                currentBB: blinds.bigBlind,
                currentAnte: blinds.ante,
                seatsAtTable: currentSeatsPerTable,
                source: .initial
            )
            tournament.stackEntries?.append(entry)
        } else {
            let entry = StackEntry(
                chipCount: tournament.startingChips,
                seatsAtTable: currentSeatsPerTable,
                source: .initial
            )
            tournament.stackEntries?.append(entry)
        }

        save()
    }

    func pauseTournament() {
        guard let tournament = activeTournament, tournament.status == .active else { return }
        tournament.status = .paused
        tournament.pausedAt = .now
        save()
    }

    func resumeTournament() {
        guard let tournament = activeTournament, tournament.status != .completed else { return }
        foldInPauseTime(for: tournament)
        tournament.status = .active
        save()
    }

    func completeTournament(position: Int? = nil, payout: Int? = nil, endDate: Date = .now) {
        guard let tournament = activeTournament, tournament.status != .completed else { return }
        foldInPauseTime(for: tournament, until: endDate)
        tournament.status = .completed
        tournament.finishPosition = position
        tournament.payout = payout ?? 0
        tournament.endDate = endDate
        save()
        // Keep tournament alive for recap — do NOT clear activeTournament yet
        completedTournamentForRecap = tournament
        showSessionRecap = true
    }

    /// Folds any in-flight pause interval into accumulatedPauseSeconds.
    private func foldInPauseTime(for tournament: Tournament, until reference: Date = .now) {
        guard let pausedAt = tournament.pausedAt else { return }
        tournament.accumulatedPauseSeconds += max(0, Int(reference.timeIntervalSince(pausedAt)))
        tournament.pausedAt = nil
    }

    func showEndTournamentSheet() {
        showEndTournament = true
    }

    func dismissRecap() {
        showSessionRecap = false
        completedTournamentForRecap = nil
        activeTournament = nil
    }

    // MARK: - Updates

    /// True when there is a live (non-completed) tournament that may be mutated.
    private var mutableTournament: Tournament? {
        guard let tournament = activeTournament, tournament.status != .completed else { return nil }
        return tournament
    }

    /// Current seats-per-table setting, read once per call site.
    private var currentSeatsPerTable: Int {
        UserDefaults.standard.object(forKey: SettingsKeys.defaultSeatsPerTable) as? Int ?? 9
    }

    func updateStack(chipCount: Int) {
        guard let tournament = mutableTournament else { return }

        let blinds = tournament.currentBlinds
        let entry = StackEntry(
            chipCount: chipCount,
            blindLevelNumber: tournament.currentBlindLevelNumber,
            currentSB: blinds?.smallBlind ?? 0,
            currentBB: blinds?.bigBlind ?? 0,
            currentAnte: blinds?.ante ?? 0,
            seatsAtTable: currentSeatsPerTable,
            source: .chat
        )
        tournament.stackEntries?.append(entry)
        save()
    }

    func updateBlinds(levelNumber: Int? = nil, sb: Int? = nil, bb: Int? = nil, ante: Int? = nil, isDisplayLevel: Bool = false) {
        guard let tournament = mutableTournament else { return }

        if let levelNumber {
            // Convert display level to internal level if needed (e.g. user says "level 4" in chat)
            let mapped = isDisplayLevel ? (tournament.internalLevelNumbers[levelNumber] ?? levelNumber) : levelNumber
            let resolvedLevel = skipBreaks(from: mapped, in: tournament)
            tournament.currentBlindLevelNumber = resolvedLevel

            // If we have this level in blind structure, update from it
            if let existing = (tournament.blindLevels ?? []).first(where: { $0.levelNumber == resolvedLevel }) {
                // Level exists — apply overrides if provided, otherwise keep structure values
                if let sb { existing.smallBlind = sb }
                if let bb { existing.bigBlind = bb }
                if let ante { existing.ante = ante }
                save()
                return
            }

            // Level doesn't exist in structure — create it with provided or zero values,
            // using the same resolved level number we just set as current.
            if let sb, let bb {
                let newLevel = BlindLevel(
                    levelNumber: resolvedLevel,
                    smallBlind: sb,
                    bigBlind: bb,
                    ante: ante ?? 0
                )
                tournament.blindLevels?.append(newLevel)
            }
            save()
            return
        }

        // No level number provided — only blinds values
        guard let sb, let bb else {
            save()
            return
        }

        // Check if any existing level already matches these blinds
        if let matchingLevel = tournament.sortedBlindLevels.first(where: {
            $0.smallBlind == sb && $0.bigBlind == bb && !$0.isBreak
        }) {
            tournament.currentBlindLevelNumber = matchingLevel.levelNumber
            if let ante { matchingLevel.ante = ante }
        } else {
            // Create a new level at the next available level number
            let nextLevelNum = ((tournament.blindLevels ?? []).map(\.levelNumber).max() ?? 0) + 1
            let newLevel = BlindLevel(
                levelNumber: nextLevelNum,
                smallBlind: sb,
                bigBlind: bb,
                ante: ante ?? 0
            )
            tournament.blindLevels?.append(newLevel)
            tournament.currentBlindLevelNumber = nextLevelNum
        }

        save()
    }

    func updateField(totalEntries: Int? = nil, playersRemaining: Int? = nil) {
        guard let tournament = mutableTournament else { return }

        if let totalEntries {
            tournament.fieldSize = totalEntries
        }
        if let playersRemaining {
            tournament.playersRemaining = playersRemaining
        }

        // Calculate average stack for snapshot
        let avgStack = tournament.averageStack

        let snapshot = FieldSnapshot(
            totalEntries: tournament.fieldSize,
            playersRemaining: tournament.playersRemaining,
            avgStack: avgStack > 0 ? avgStack : nil
        )
        tournament.fieldSnapshots?.append(snapshot)

        save()
    }

    func recordBounty() {
        guard let tournament = mutableTournament else { return }
        tournament.bountiesCollected += 1

        let event = BountyEvent(
            amount: tournament.bountyAmount
        )
        tournament.bountyEvents?.append(event)

        save()
    }

    func recordRebuy() {
        guard let tournament = mutableTournament else { return }
        tournament.rebuysUsed += 1

        // Reset stack to starting chips
        let blinds = tournament.currentBlinds
        let entry = StackEntry(
            chipCount: tournament.startingChips,
            blindLevelNumber: tournament.currentBlindLevelNumber,
            currentSB: blinds?.smallBlind ?? 0,
            currentBB: blinds?.bigBlind ?? 0,
            currentAnte: blinds?.ante ?? 0,
            seatsAtTable: currentSeatsPerTable,
            source: .chat
        )
        tournament.stackEntries?.append(entry)

        save()
    }

    func recordHandNote(_ text: String) {
        guard let tournament = mutableTournament else { return }
        let blinds = tournament.currentBlinds
        let note = HandNote(
            descriptionText: text,
            stackBefore: tournament.latestStack?.chipCount,
            stackAfter: nil,
            blindLevelNumber: tournament.currentBlindLevelNumber,
            blindsDisplay: blinds?.blindsDisplay ?? ""
        )
        tournament.handNotes?.append(note)
        save()
    }

    func addHandNote(text: String, stackBefore: Int? = nil) {
        guard let tournament = mutableTournament else { return }
        let blinds = tournament.currentBlinds
        let note = HandNote(
            descriptionText: text,
            stackBefore: stackBefore ?? tournament.latestStack?.chipCount,
            stackAfter: nil,
            blindLevelNumber: tournament.currentBlindLevelNumber,
            blindsDisplay: blinds?.blindsDisplay ?? ""
        )
        tournament.handNotes?.append(note)
        save()
    }

    func updateHandNote(_ note: HandNote, text: String) {
        note.descriptionText = text
        save()
    }

    func deleteHandNote(_ note: HandNote) {
        guard let tournament = activeTournament else { return }
        tournament.handNotes?.removeAll { $0.persistentModelID == note.persistentModelID }
        modelContext?.delete(note)
        save()
    }

    func setCurrentLevel(_ levelNumber: Int) {
        guard let tournament = mutableTournament else { return }
        tournament.currentBlindLevelNumber = skipBreaks(from: levelNumber, in: tournament)
        save()
    }

    /// If the target level is a break, advance to the next non-break level.
    private func skipBreaks(from levelNumber: Int, in tournament: Tournament) -> Int {
        let sorted = tournament.sortedBlindLevels
        guard let idx = sorted.firstIndex(where: { $0.levelNumber == levelNumber }),
              sorted[idx].isBreak else {
            return levelNumber
        }
        // Walk forward past consecutive breaks
        for i in (idx + 1)..<sorted.count {
            if !sorted[i].isBreak {
                return sorted[i].levelNumber
            }
        }
        return levelNumber
    }

    func addBlindLevel(smallBlind: Int, bigBlind: Int, ante: Int = 0, durationMinutes: Int = 30) {
        guard let tournament = mutableTournament else { return }
        let nextNum = ((tournament.blindLevels ?? []).map(\.levelNumber).max() ?? 0) + 1
        let level = BlindLevel(
            levelNumber: nextNum,
            smallBlind: smallBlind,
            bigBlind: bigBlind,
            ante: ante,
            durationMinutes: durationMinutes
        )
        tournament.blindLevels?.append(level)
        save()
    }

    func deleteBlindLevel(_ level: BlindLevel) {
        guard let tournament = activeTournament else { return }
        tournament.blindLevels?.removeAll { $0.persistentModelID == level.persistentModelID }
        modelContext?.delete(level)
        save()
    }

    // MARK: - Break Timer

    func startBreak(tableNumber: String, seatNumber: String, chipCount: Int, duration: Int, photoData: Data? = nil) {
        guard let tournament = mutableTournament else { return }

        let blinds = tournament.currentBlinds
        let entry = BreakEntry(
            tableNumber: tableNumber,
            seatNumber: seatNumber,
            chipCount: chipCount,
            breakDurationSeconds: duration,
            blindLevelNumber: tournament.currentBlindLevelNumber,
            blindsDisplay: blinds?.blindsDisplay ?? "",
            chipPhotoData: photoData
        )
        tournament.breakEntries?.append(entry)

        isOnBreak = true
        breakEndTime = Date.now.addingTimeInterval(TimeInterval(duration))

        scheduleBreakNotifications(tableNumber: tableNumber, seatNumber: seatNumber, chipCount: chipCount, duration: duration)
        save()
    }

    func endBreak() {
        isOnBreak = false
        breakEndTime = nil
        cancelBreakNotifications()
        save()
    }

    /// Re-derives transient break state from the latest persisted BreakEntry,
    /// so an in-progress break survives app relaunch. Called whenever
    /// `activeTournament` is assigned/restored.
    func restoreBreakState() {
        isOnBreak = false
        breakEndTime = nil
        guard let tournament = activeTournament,
              tournament.status != .completed,
              let latest = tournament.sortedBreakEntries.last else { return }
        let end = latest.timestamp.addingTimeInterval(TimeInterval(latest.breakDurationSeconds))
        if end > .now {
            isOnBreak = true
            breakEndTime = end
        }
    }

    func deleteBreakEntry(_ entry: BreakEntry) {
        guard let tournament = activeTournament else { return }
        tournament.breakEntries?.removeAll { $0.persistentModelID == entry.persistentModelID }
        modelContext?.delete(entry)
        save()
    }

    private func scheduleBreakNotifications(tableNumber: String, seatNumber: String, chipCount: Int, duration: Int) {
        let center = UNUserNotificationCenter.current()

        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                if let error {
                    Self.logger.error("Notification authorization failed: \(error.localizedDescription)")
                }
                if !granted {
                    Self.logger.notice("Notification authorization denied — break alerts will not be delivered")
                }
                self?.notificationsDenied = !granted
            }
        }

        // 2-minute warning (only if break is longer than 2 minutes)
        if duration > 120 {
            let warningContent = UNMutableNotificationContent()
            warningContent.title = "Break ending soon"
            warningContent.body = "2 minutes remaining — Table \(tableNumber), Seat \(seatNumber)"
            warningContent.sound = .default

            let warningTrigger = UNTimeIntervalNotificationTrigger(
                timeInterval: TimeInterval(duration - 120), repeats: false
            )
            let warningRequest = UNNotificationRequest(
                identifier: "break-2min-warning", content: warningContent, trigger: warningTrigger
            )
            center.add(warningRequest)
        }

        // Break over
        let overContent = UNMutableNotificationContent()
        overContent.title = "Break is over!"
        overContent.body = "Return to Table \(tableNumber), Seat \(seatNumber) — \(chipCount.formatted()) chips"
        overContent.sound = .default

        let overTrigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(duration), repeats: false
        )
        let overRequest = UNNotificationRequest(
            identifier: "break-over", content: overContent, trigger: overTrigger
        )
        center.add(overRequest)
    }

    private func cancelBreakNotifications() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["break-2min-warning", "break-over"]
        )
    }

    // MARK: - Persistence

    private func save() {
        guard let modelContext else { return }
        do {
            try modelContext.save()
            lastSaveError = nil
        } catch {
            Self.logger.error("Failed to save model context: \(error.localizedDescription)")
            lastSaveError = error.localizedDescription
        }
    }
}
