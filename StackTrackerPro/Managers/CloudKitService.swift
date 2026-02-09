import CloudKit
import CoreLocation

// MARK: - Errors

enum CloudKitServiceError: LocalizedError {
    case duplicateSkipped

    var errorDescription: String? {
        switch self {
        case .duplicateSkipped:
            return "Duplicate tournament — already shared."
        }
    }
}

// MARK: - SharedTournamentListing

struct SharedTournamentListing: Identifiable {
    let id: String // CKRecord.ID.recordName
    var tournamentName: String
    var venueName: String
    var venueCity: String
    var venueState: String
    var gameType: String
    var buyIn: Int
    var entryFee: Int
    var bountyAmount: Int
    var guarantee: Int
    var startingChips: Int
    var startingSB: Int
    var startingBB: Int
    var reentryPolicy: String
    var eventDate: Date
    var latitude: Double
    var longitude: Double
    var blindLevels: [BlindLevelCodable]
    var contributedAt: Date

    func toScanResult() -> PokerAtlasScanResult {
        var result = PokerAtlasScanResult()
        result.tournamentName = tournamentName
        result.venueName = venueName
        result.gameType = GameType(rawValue: gameType)
        result.buyIn = buyIn > 0 ? buyIn : nil
        result.entryFee = entryFee > 0 ? entryFee : nil
        result.bountyAmount = bountyAmount > 0 ? bountyAmount : nil
        result.guarantee = guarantee > 0 ? guarantee : nil
        result.startingChips = startingChips > 0 ? startingChips : nil
        result.reentryPolicy = reentryPolicy
        result.startingSB = startingSB > 0 ? startingSB : nil
        result.startingBB = startingBB > 0 ? startingBB : nil
        result.blindLevels = blindLevels.map { $0.toScannedBlindLevel() }
        return result
    }
}

// MARK: - Distance Helpers

extension SharedTournamentListing {
    func distanceMiles(from userLocation: CLLocation) -> Double {
        let listingLocation = CLLocation(latitude: latitude, longitude: longitude)
        let meters = userLocation.distance(from: listingLocation)
        return meters / 1609.344
    }

    func distanceFormatted(from userLocation: CLLocation) -> String {
        let miles = distanceMiles(from: userLocation)
        if miles < 1 {
            return "< 1 mi"
        } else if miles < 10 {
            return String(format: "%.1f mi", miles)
        } else {
            return String(format: "%.0f mi", miles)
        }
    }
}

// MARK: - BlindLevelCodable

struct BlindLevelCodable: Codable {
    var levelNumber: Int
    var smallBlind: Int
    var bigBlind: Int
    var ante: Int
    var durationMinutes: Int
    var isBreak: Bool
    var breakLabel: String?

    init(from scanned: ScannedBlindLevel) {
        self.levelNumber = scanned.levelNumber
        self.smallBlind = scanned.smallBlind
        self.bigBlind = scanned.bigBlind
        self.ante = scanned.ante
        self.durationMinutes = scanned.durationMinutes
        self.isBreak = scanned.isBreak
        self.breakLabel = scanned.breakLabel
    }

    func toScannedBlindLevel() -> ScannedBlindLevel {
        ScannedBlindLevel(
            levelNumber: levelNumber,
            smallBlind: smallBlind,
            bigBlind: bigBlind,
            ante: ante,
            durationMinutes: durationMinutes,
            isBreak: isBreak,
            breakLabel: breakLabel
        )
    }
}

// MARK: - CloudKitService

@MainActor
final class CloudKitService: @unchecked Sendable {
    static let shared = CloudKitService()

    private let container = CKContainer(identifier: "iCloud.com.gyndok.stacktrackerpro")
    private var database: CKDatabase { container.publicCloudDatabase }
    private let recordType = "SharedTournament"

    private init() {}

    // MARK: - Field Keys

    private enum Fields {
        static let tournamentName = "tournamentName"
        static let venueName = "venueName"
        static let venueCity = "venueCity"
        static let venueState = "venueState"
        static let gameTypeRaw = "gameTypeRaw"
        static let buyIn = "buyIn"
        static let entryFee = "entryFee"
        static let bountyAmount = "bountyAmount"
        static let guarantee = "guarantee"
        static let startingChips = "startingChips"
        static let startingSB = "startingSB"
        static let startingBB = "startingBB"
        static let reentryPolicy = "reentryPolicy"
        static let eventDate = "eventDate"
        static let latitude = "latitude"
        static let longitude = "longitude"
        static let blindLevelsJSON = "blindLevelsJSON"
        static let deduplicationKey = "deduplicationKey"
        static let contributedAt = "contributedAt"
    }

    // MARK: - Save

    func saveTournament(
        scanResult: PokerAtlasScanResult,
        eventDate: Date,
        latitude: Double,
        longitude: Double,
        venueCity: String,
        venueState: String
    ) async throws {
        let dedupKey = buildDeduplicationKey(
            venueName: scanResult.venueName ?? "",
            eventDate: eventDate,
            buyIn: scanResult.buyIn ?? 0,
            gameType: scanResult.gameType?.rawValue ?? ""
        )

        // Check for existing record with same dedup key
        let predicate = NSPredicate(format: "%K == %@", Fields.deduplicationKey, dedupKey)
        let query = CKQuery(recordType: recordType, predicate: predicate)
        if let (existingResults, _) = try? await database.records(matching: query, resultsLimit: 1),
           !existingResults.isEmpty {
            throw CloudKitServiceError.duplicateSkipped
        }

        let record = CKRecord(recordType: recordType)
        record[Fields.tournamentName] = (scanResult.tournamentName ?? "") as CKRecordValue
        record[Fields.venueName] = (scanResult.venueName ?? "") as CKRecordValue
        record[Fields.venueCity] = venueCity as CKRecordValue
        record[Fields.venueState] = venueState as CKRecordValue
        record[Fields.gameTypeRaw] = (scanResult.gameType?.rawValue ?? "NLH") as CKRecordValue
        record[Fields.buyIn] = (scanResult.buyIn ?? 0) as CKRecordValue
        record[Fields.entryFee] = (scanResult.entryFee ?? 0) as CKRecordValue
        record[Fields.bountyAmount] = (scanResult.bountyAmount ?? 0) as CKRecordValue
        record[Fields.guarantee] = (scanResult.guarantee ?? 0) as CKRecordValue
        record[Fields.startingChips] = (scanResult.startingChips ?? 0) as CKRecordValue
        record[Fields.startingSB] = (scanResult.startingSB ?? 0) as CKRecordValue
        record[Fields.startingBB] = (scanResult.startingBB ?? 0) as CKRecordValue
        record[Fields.reentryPolicy] = (scanResult.reentryPolicy ?? "None") as CKRecordValue
        record[Fields.eventDate] = eventDate as CKRecordValue
        record[Fields.latitude] = latitude as CKRecordValue
        record[Fields.longitude] = longitude as CKRecordValue
        record[Fields.deduplicationKey] = dedupKey as CKRecordValue
        record[Fields.contributedAt] = Date() as CKRecordValue

        // Encode blind levels as JSON string
        let codableLevels = scanResult.blindLevels.map { BlindLevelCodable(from: $0) }
        if let jsonData = try? JSONEncoder().encode(codableLevels),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            record[Fields.blindLevelsJSON] = jsonString as CKRecordValue
        }

        _ = try await database.save(record)
    }

    // MARK: - Fetch Nearby

    func fetchNearby(latitude: Double, longitude: Double, radiusMiles: Double = 50) async throws -> [SharedTournamentListing] {
        let radiusDegrees = radiusMiles / 69.0 // ~69 miles per degree latitude
        let lonRadiusDegrees = radiusMiles / (69.0 * cos(latitude * .pi / 180))

        let minLat = latitude - radiusDegrees
        let maxLat = latitude + radiusDegrees
        let minLon = longitude - lonRadiusDegrees
        let maxLon = longitude + lonRadiusDegrees

        let today = Calendar.current.startOfDay(for: Date())
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: today)!

        let predicate = NSPredicate(
            format: "%K >= %@ AND %K <= %@ AND %K >= %@ AND %K <= %@ AND %K >= %@ AND %K < %@",
            Fields.latitude, NSNumber(value: minLat),
            Fields.latitude, NSNumber(value: maxLat),
            Fields.longitude, NSNumber(value: minLon),
            Fields.longitude, NSNumber(value: maxLon),
            Fields.eventDate, today as NSDate,
            Fields.eventDate, endOfToday as NSDate
        )

        let query = CKQuery(recordType: recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: Fields.eventDate, ascending: true)]

        let results: [(CKRecord.ID, Result<CKRecord, Error>)]
        do {
            let (r, _) = try await database.records(matching: query, resultsLimit: 100)
            results = r
        } catch let error as CKError where error.code == .unknownItem {
            // Record type doesn't exist yet — no one has shared; return empty
            return []
        }

        var listings: [SharedTournamentListing] = []
        for (_, result) in results {
            if let record = try? result.get() {
                if let listing = parseListing(from: record) {
                    listings.append(listing)
                }
            }
        }

        // Client-side deduplication: keep most recently contributed per dedup key
        return deduplicateListings(listings)
    }

    // MARK: - Private Helpers

    private func buildDeduplicationKey(venueName: String, eventDate: Date, buyIn: Int, gameType: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: eventDate)
        return "\(venueName)|\(dateStr)|\(buyIn)|\(gameType)"
    }

    private func parseListing(from record: CKRecord) -> SharedTournamentListing? {
        guard let tournamentName = record[Fields.tournamentName] as? String,
              let venueName = record[Fields.venueName] as? String,
              let eventDate = record[Fields.eventDate] as? Date,
              let latitude = record[Fields.latitude] as? Double,
              let longitude = record[Fields.longitude] as? Double else {
            return nil
        }

        var blindLevels: [BlindLevelCodable] = []
        if let jsonString = record[Fields.blindLevelsJSON] as? String,
           let jsonData = jsonString.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([BlindLevelCodable].self, from: jsonData) {
            blindLevels = decoded
        }

        return SharedTournamentListing(
            id: record.recordID.recordName,
            tournamentName: tournamentName,
            venueName: venueName,
            venueCity: record[Fields.venueCity] as? String ?? "",
            venueState: record[Fields.venueState] as? String ?? "",
            gameType: record[Fields.gameTypeRaw] as? String ?? "NLH",
            buyIn: record[Fields.buyIn] as? Int ?? 0,
            entryFee: record[Fields.entryFee] as? Int ?? 0,
            bountyAmount: record[Fields.bountyAmount] as? Int ?? 0,
            guarantee: record[Fields.guarantee] as? Int ?? 0,
            startingChips: record[Fields.startingChips] as? Int ?? 0,
            startingSB: record[Fields.startingSB] as? Int ?? 0,
            startingBB: record[Fields.startingBB] as? Int ?? 0,
            reentryPolicy: record[Fields.reentryPolicy] as? String ?? "None",
            eventDate: eventDate,
            latitude: latitude,
            longitude: longitude,
            blindLevels: blindLevels,
            contributedAt: record[Fields.contributedAt] as? Date ?? Date()
        )
    }

    private func deduplicateListings(_ listings: [SharedTournamentListing]) -> [SharedTournamentListing] {
        var seen: [String: SharedTournamentListing] = [:]
        for listing in listings {
            let key = buildDeduplicationKey(
                venueName: listing.venueName,
                eventDate: listing.eventDate,
                buyIn: listing.buyIn,
                gameType: listing.gameType
            )
            if let existing = seen[key] {
                if listing.contributedAt > existing.contributedAt {
                    seen[key] = listing
                }
            } else {
                seen[key] = listing
            }
        }
        return Array(seen.values).sorted { $0.eventDate < $1.eventDate }
    }
}
