import XCTest
import SwiftData
@testable import StackTrackerPro

// MARK: - Shared helpers

@MainActor
private func makeInMemoryContainer() throws -> ModelContainer {
    // Mirror the full schema from StackTrackerProApp.
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
        BreakEntry.self,
        BlindStructureTemplate.self,
    ])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

private func writeTempCSV(_ content: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("StackTrackerProTests-\(UUID().uuidString).csv")
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
}

// MARK: - RegexPokerParser

final class RegexPokerParserTests: XCTestCase {

    private let parser = RegexPokerParser.shared

    func testHandNoteSuppressesAllOtherExtraction() {
        let result = parser.parse("note: villain busted my aces with a flush")

        XCTAssertEqual(result.handNote, "villain busted my aces with a flush")
        XCTAssertFalse(result.isEliminated, "hand note must not trigger an elimination")
        XCTAssertNil(result.finishPosition)
        XCTAssertNil(result.chipCount)
        XCTAssertFalse(result.bountyCollected)
        XCTAssertFalse(result.tookRebuy)
        XCTAssertNil(result.payoutAmount)
        XCTAssertNil(result.smallBlind)
        XCTAssertNil(result.bigBlind)
    }

    func testHandNotePrefixVariants() {
        XCTAssertEqual(parser.parse("hand note: flopped a set").handNote, "flopped a set")
        XCTAssertEqual(parser.parse("HN: cooler vs kings").handNote, "cooler vs kings")
        let noted = parser.parse("noted: hero call with third pair")
        XCTAssertEqual(noted.handNote, "hero call with third pair")
        XCTAssertFalse(noted.isEliminated)
    }

    func testBlindsNotationDoesNotRecordStack() {
        let result = parser.parse("now at 500/1000")

        XCTAssertEqual(result.smallBlind, 500)
        XCTAssertEqual(result.bigBlind, 1000)
        XCTAssertNil(result.chipCount, "'at 500/1000' is blinds, not a 500 stack")
    }

    func testBlindsWithAnteAndKSuffix() {
        let result = parser.parse("blinds 1k/2k/2k")

        XCTAssertEqual(result.smallBlind, 1000)
        XCTAssertEqual(result.bigBlind, 2000)
        XCTAssertEqual(result.ante, 2000)
    }

    func testStackParsingKSuffix() {
        XCTAssertEqual(parser.parse("I have 32k").chipCount, 32000)
    }

    func testStackParsingCommaSeparated() {
        XCTAssertEqual(parser.parse("stack is 125,000").chipCount, 125_000)
    }

    func testEliminationWithPositionDetectedWithoutNotePrefix() {
        let result = parser.parse("busted in 14th")

        XCTAssertTrue(result.isEliminated)
        XCTAssertEqual(result.finishPosition, 14)
    }

    func testEliminationWithoutPosition() {
        let result = parser.parse("I'm out")
        XCTAssertTrue(result.isEliminated)
        XCTAssertNil(result.finishPosition)
    }

    func testBountyDetected() {
        XCTAssertTrue(parser.parse("got a bounty").bountyCollected)
        XCTAssertTrue(parser.parse("knocked him out").bountyCollected)
    }

    func testSmallPayoutAmountIsNotDropped() {
        // Documented behavior: no minimum threshold on payout amounts.
        XCTAssertEqual(parser.parse("cashed for $5").payoutAmount, 5)
        XCTAssertEqual(parser.parse("won $8").payoutAmount, 8)
    }

    func testBountyDollarAmountIsNotMisrecordedAsPayout() {
        // "got $100 bounty" describes the bounty, not prize money.
        let result = parser.parse("got $100 bounty")

        XCTAssertTrue(result.bountyCollected)
        XCTAssertNil(result.payoutAmount,
                     "an amount qualifying the bounty itself must not become a payout")
    }

    func testParseChipValueSuffixes() {
        XCTAssertEqual(parser.parseChipValue("32k"), 32000)
        XCTAssertEqual(parser.parseChipValue("1.5m"), 1_500_000)
        XCTAssertEqual(parser.parseChipValue("45000"), 45000)
        XCTAssertEqual(parser.parseChipValue("junk"), 0)
    }
}

// MARK: - ParsedEntities sanitization (defense in depth)

final class ParsedEntitiesSanitizationTests: XCTestCase {

    func testDropsNonPositiveAndImplausiblyHugeChipCount() {
        var e = ParsedEntities()
        e.chipCount = 0
        XCTAssertNil(e.sanitized().chipCount)

        e.chipCount = -500
        XCTAssertNil(e.sanitized().chipCount)

        e.chipCount = 5_000_000_000 // 5 billion chips — garbage from a bad parse
        XCTAssertNil(e.sanitized().chipCount)

        e.chipCount = 32_000 // valid
        XCTAssertEqual(e.sanitized().chipCount, 32_000)
    }

    func testDropsInconsistentBlinds() {
        var e = ParsedEntities()
        e.smallBlind = 1000
        e.bigBlind = 500 // BB < SB is a misparse — drop both
        let s = e.sanitized()
        XCTAssertNil(s.smallBlind)
        XCTAssertNil(s.bigBlind)
    }

    func testKeepsValidBlinds() {
        var e = ParsedEntities()
        e.smallBlind = 500
        e.bigBlind = 1000
        e.ante = 1000
        let s = e.sanitized()
        XCTAssertEqual(s.smallBlind, 500)
        XCTAssertEqual(s.bigBlind, 1000)
        XCTAssertEqual(s.ante, 1000)
    }

    func testDropsRemainingExceedingField() {
        var e = ParsedEntities()
        e.totalEntries = 500
        e.playersRemaining = 5000 // impossible — more left than entered
        let s = e.sanitized()
        XCTAssertEqual(s.totalEntries, 500)
        XCTAssertNil(s.playersRemaining)
    }

    func testDropsNonPositiveFieldCounts() {
        var e = ParsedEntities()
        e.totalEntries = 0
        e.playersRemaining = -3
        let s = e.sanitized()
        XCTAssertNil(s.totalEntries)
        XCTAssertNil(s.playersRemaining)
    }

    func testPreservesFlagsAndNote() {
        var e = ParsedEntities()
        e.bountyCollected = true
        e.tookRebuy = true
        e.handNote = "cooler vs kings"
        let s = e.sanitized()
        XCTAssertTrue(s.bountyCollected)
        XCTAssertTrue(s.tookRebuy)
        XCTAssertEqual(s.handNote, "cooler vs kings")
    }
}

// MARK: - Tournament math

final class TournamentMathTests: XCTestCase {

    @MainActor
    func testPrizePoolSubtractsFeeBountyAndDeductions() throws {
        let container = try makeInMemoryContainer()
        let t = Tournament(name: "PKO", buyIn: 250, entryFee: 30, bountyAmount: 100)
        container.mainContext.insert(t)
        t.fieldSize = 100

        XCTAssertEqual(t.prizePoolContributionPerPlayer, 120,
                       "250 buy-in - 30 fee - 100 bounty = 120 per player")
        XCTAssertEqual(t.prizePool, 12_000)
        XCTAssertEqual(t.houseRake, 3_000)
    }

    @MainActor
    func testPrizePoolContributionClampedAtZero() throws {
        let container = try makeInMemoryContainer()
        let t = Tournament(name: "Weird", buyIn: 100, entryFee: 80, deductions: 50)
        container.mainContext.insert(t)
        t.fieldSize = 40

        XCTAssertEqual(t.prizePoolContributionPerPlayer, 0)
        XCTAssertEqual(t.prizePool, 0)
    }

    @MainActor
    func testAverageStackAtBubble() throws {
        let container = try makeInMemoryContainer()
        let t = Tournament(name: "Bubble", buyIn: 200)
        container.mainContext.insert(t)
        t.startingChips = 20_000
        t.fieldSize = 100
        t.payoutPercent = 15.0

        // 100 entries × 20,000 = 2,000,000 chips. 15% of 100 = 15 paid spots.
        // 2,000,000 / 15 = 133,333.
        XCTAssertEqual(t.paidSpots, 15)
        XCTAssertEqual(t.averageStackAtBubble, 133_333)
    }

    @MainActor
    func testAverageStackAtBubbleZeroUntilKnown() throws {
        let container = try makeInMemoryContainer()
        let t = Tournament(name: "Empty", buyIn: 100)
        container.mainContext.insert(t)
        t.startingChips = 20_000
        t.fieldSize = 0 // unknown field
        XCTAssertEqual(t.averageStackAtBubble, 0)
        XCTAssertEqual(t.paidSpots, 0)
    }

    @MainActor
    func testAverageStackAtFinalTable() throws {
        let container = try makeInMemoryContainer()
        let t = Tournament(name: "FT", buyIn: 200)
        container.mainContext.insert(t)
        t.startingChips = 20_000
        t.fieldSize = 100

        // 100 × 20,000 = 2,000,000 chips ÷ 9 seats = 222,222.
        XCTAssertEqual(t.averageStackAtFinalTable, 222_222)
    }

    @MainActor
    func testAverageStackAtFinalTableZeroWhenFieldBelowNine() throws {
        let container = try makeInMemoryContainer()
        let t = Tournament(name: "Small", buyIn: 100)
        container.mainContext.insert(t)
        t.startingChips = 20_000
        t.fieldSize = 6 // smaller than a full final table
        XCTAssertEqual(t.averageStackAtFinalTable, 0)
    }

    @MainActor
    func testAddOnsAffectChipsPoolRakeAndInvestment() throws {
        let container = try makeInMemoryContainer()
        let t = Tournament(name: "AddOn", buyIn: 250, entryFee: 195)
        container.mainContext.insert(t)
        t.startingChips = 30_000
        t.fieldSize = 100
        t.addOnAvailable = true
        t.addOnCost = 100
        t.addOnRake = 10
        t.addOnChips = 30_000
        t.addOnsCount = 40      // 40 of the field took the add-on
        t.playerAddOnsUsed = 1  // I took one

        // Derived split: 100 - 10 = 90 to the pool.
        XCTAssertEqual(t.addOnToPrizePool, 90)

        // Chips: 100 × 30,000 + 40 × 30,000 = 4,200,000.
        XCTAssertEqual(t.totalChipsInPlay, 4_200_000)

        // Prize pool: per-player (250 - 195 = 55) × 100 + 40 × 90
        //           = 5,500 + 3,600 = 9,100.
        XCTAssertEqual(t.prizePool, 9_100)

        // House rake: 195 × 100 + 40 × 10 = 19,500 + 400 = 19,900.
        XCTAssertEqual(t.houseRake, 19_900)

        // Investment: 250 buy-in + 1 add-on × 100 = 350.
        XCTAssertEqual(t.totalInvestment, 350)
    }

    @MainActor
    func testAddOnsIgnoredWhenUnavailable() throws {
        let container = try makeInMemoryContainer()
        let t = Tournament(name: "NoAddOn", buyIn: 250, entryFee: 195)
        container.mainContext.insert(t)
        t.startingChips = 30_000
        t.fieldSize = 100
        // Stale add-on values present but the feature is off — must be ignored.
        t.addOnAvailable = false
        t.addOnChips = 30_000
        t.addOnsCount = 40
        t.playerAddOnsUsed = 1
        t.addOnCost = 100

        XCTAssertEqual(t.totalChipsInPlay, 3_000_000)   // 100 × 30,000 only
        XCTAssertEqual(t.prizePool, 5_500)              // 55 × 100 only
        XCTAssertEqual(t.totalInvestment, 250)          // no add-on cost
    }

    @MainActor
    func testLiveAverageStackIncludesAddOnChips() throws {
        // Regression: live Avg Stack must include add-on chips, not just
        // buy-in chips. Mirrors the reported case (120 entries × 30k + 65
        // add-ons × 30k = 5,550,000 chips, 110 left → 50,454, not 32,727).
        let container = try makeInMemoryContainer()
        let t = Tournament(name: "Live", buyIn: 250)
        container.mainContext.insert(t)
        t.startingChips = 30_000
        t.fieldSize = 120
        t.playersRemaining = 110
        t.addOnAvailable = true
        t.addOnChips = 30_000
        t.addOnsCount = 65

        XCTAssertEqual(t.totalChipsInPlay, 5_550_000)
        XCTAssertEqual(t.averageStack, 5_550_000 / 110) // 50,454
        XCTAssertNotEqual(t.averageStack, 32_727)
    }

    @MainActor
    func testAddOnsRaiseAverageStackProjections() throws {
        let container = try makeInMemoryContainer()
        let t = Tournament(name: "AddOnAvg", buyIn: 250)
        container.mainContext.insert(t)
        t.startingChips = 30_000
        t.fieldSize = 100
        t.payoutPercent = 15.0
        t.addOnAvailable = true
        t.addOnChips = 30_000
        t.addOnsCount = 100 // everyone added on → 6,000,000 chips total

        // 6,000,000 ÷ 15 paid = 400,000 at the bubble.
        XCTAssertEqual(t.averageStackAtBubble, 400_000)
        // 6,000,000 ÷ 9 = 666,666 at the final table.
        XCTAssertEqual(t.averageStackAtFinalTable, 666_666)
    }

    @MainActor
    func testBountyWinningsPrefersBountyEvents() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let t = Tournament(name: "PKO", buyIn: 250, bountyAmount: 50)
        context.insert(t)

        let e1 = BountyEvent(amount: 100)
        let e2 = BountyEvent(amount: 250)
        context.insert(e1)
        context.insert(e2)
        t.bountyEvents = [e1, e2]
        // Stale legacy counter should be ignored when events exist.
        t.bountiesCollected = 7

        XCTAssertEqual(t.bountyWinnings, 350)
    }

    @MainActor
    func testBountyWinningsFallsBackToCountTimesFlatAmount() throws {
        let container = try makeInMemoryContainer()
        let t = Tournament(name: "KO", buyIn: 100, bountyAmount: 50)
        container.mainContext.insert(t)
        t.bountiesCollected = 3

        XCTAssertEqual(t.bountyWinnings, 150)
    }

    @MainActor
    func testDurationUsesActualStartDateAndSubtractsPauses() throws {
        let container = try makeInMemoryContainer()
        let t = Tournament(name: "Timing")
        container.mainContext.insert(t)

        let end = Date(timeIntervalSince1970: 2_000_000)
        t.startDate = end.addingTimeInterval(-50_000)       // scheduled long before
        t.actualStartDate = end.addingTimeInterval(-3_600)  // actually started 1h before end
        t.accumulatedPauseSeconds = 600
        t.endDate = end

        XCTAssertEqual(t.duration, 3_000, "1h active minus 600s of pauses")
    }

    @MainActor
    func testDurationNeverNegative() throws {
        let container = try makeInMemoryContainer()
        let t = Tournament(name: "Clock skew")
        container.mainContext.insert(t)

        let end = Date(timeIntervalSince1970: 2_000_000)
        t.actualStartDate = end.addingTimeInterval(500) // started "after" the end
        t.endDate = end
        XCTAssertEqual(t.duration, 0)

        // Pauses larger than elapsed time also clamp to zero.
        t.actualStartDate = end.addingTimeInterval(-100)
        t.accumulatedPauseSeconds = 10_000
        XCTAssertEqual(t.duration, 0)
    }

    @MainActor
    func testDurationNilUntilEnded() throws {
        let container = try makeInMemoryContainer()
        let t = Tournament(name: "Running")
        container.mainContext.insert(t)
        XCTAssertNil(t.duration)
    }

    @MainActor
    func testEstimatedBubbleDistanceNeverNegative() throws {
        let container = try makeInMemoryContainer()
        let t = Tournament(name: "Bubble")
        container.mainContext.insert(t)
        t.fieldSize = 100
        t.payoutPercent = 15

        t.playersRemaining = 50
        XCTAssertEqual(t.estimatedBubbleDistance, 35, "50 left - 15 paid = 35 from the money")

        t.playersRemaining = 10 // already in the money
        XCTAssertEqual(t.estimatedBubbleDistance, 0)

        t.fieldSize = 0
        XCTAssertEqual(t.estimatedBubbleDistance, 0)
    }

    @MainActor
    func testProfitNilWhenPayoutNil() throws {
        let container = try makeInMemoryContainer()
        let t = Tournament(name: "No result", buyIn: 250, bountyAmount: 50)
        container.mainContext.insert(t)
        t.bountiesCollected = 2

        XCTAssertNil(t.profit, "profit must stay nil (unknown), not treat payout as 0")

        t.payout = 1_000
        t.rebuysUsed = 1
        // 1000 payout + 100 bounties - 500 invested (250 x 2 entries)
        XCTAssertEqual(t.profit, 600)
    }
}

// MARK: - CSV round-trip

final class CSVRoundTripTests: XCTestCase {

    private let multiLineNote = "Ran well early, then card dead.\nHero folded KK preflop, \"sick\" spot."

    @MainActor
    private func populateSource(_ context: ModelContext) throws {
        let calendar = Calendar(identifier: .gregorian)
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 10))!
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 1, day: 16, hour: 12))!
        let day3 = calendar.date(from: DateComponents(year: 2026, month: 1, day: 17, hour: 9))!

        // Cash session with a multi-line, comma-containing note.
        let cash = CashSession(stakes: "1/3", gameType: .nlh, buyInTotal: 300,
                               venueName: "Bellagio, Las Vegas", date: day1)
        cash.cashOut = 650
        cash.endTime = day1.addingTimeInterval(4 * 3600)
        cash.statusRaw = SessionStatus.completed.rawValue
        cash.notes = multiLineNote
        context.insert(cash)

        // Freeroll with no recorded cash-out.
        let freeroll = CashSession(stakes: "2/5", gameType: .plo, buyInTotal: 0,
                                   venueName: "Home Game", date: day3)
        freeroll.endTime = day3.addingTimeInterval(2 * 3600)
        freeroll.statusRaw = SessionStatus.completed.rawValue
        context.insert(freeroll)

        // Tournament with rebuys and bounties.
        let t = Tournament(name: "Main Event", gameType: .nlh, buyIn: 250,
                           entryFee: 30, bountyAmount: 50, startDate: day2)
        t.statusRaw = TournamentStatus.completed.rawValue
        t.endDate = day2.addingTimeInterval(8 * 3600)
        t.venueName = "Aria"
        t.finishPosition = 14
        t.fieldSize = 375
        t.rebuysUsed = 2
        t.bountiesCollected = 3
        t.payout = 1_000
        context.insert(t)

        try context.save()
    }

    @MainActor
    func testExportImportRoundTrip() throws {
        let source = try makeInMemoryContainer()
        try populateSource(source.mainContext)

        let export = CSVExporter.exportCSV(from: source.mainContext)
        XCTAssertEqual(export.totalRows, 3)
        XCTAssertEqual(export.cashCount, 2)
        XCTAssertEqual(export.tournamentCount, 1)

        let url = try writeTempCSV(export.csvString)
        defer { try? FileManager.default.removeItem(at: url) }

        let destination = try makeInMemoryContainer()
        let result = CSVImporter.importCSV(from: url, into: destination.mainContext)

        XCTAssertEqual(result.cashSessionsCreated, 2)
        XCTAssertEqual(result.tournamentsCreated, 1)
        XCTAssertEqual(result.rowsSkipped, 0)
        XCTAssertEqual(result.duplicatesSkipped, 0)

        // Tournament fields survive the round trip.
        let tournaments = try destination.mainContext.fetch(FetchDescriptor<Tournament>())
        XCTAssertEqual(tournaments.count, 1)
        let t = try XCTUnwrap(tournaments.first)
        XCTAssertEqual(t.name, "Main Event")
        XCTAssertEqual(t.finishPosition, 14)
        XCTAssertEqual(t.fieldSize, 375)
        XCTAssertEqual(t.rebuysUsed, 2)
        XCTAssertEqual(t.bountiesCollected, 3)
        XCTAssertEqual(t.bountyAmount, 50)
        XCTAssertEqual(t.buyIn, 250,
                       "base buy-in must be derived back from the exported total investment")
        XCTAssertEqual(t.payout, 1_000)
        XCTAssertEqual(t.venueName, "Aria")

        // Cash sessions: notes intact, freeroll accepted, blank cash-out stays nil.
        let sessions = try destination.mainContext.fetch(FetchDescriptor<CashSession>())
        XCTAssertEqual(sessions.count, 2)
        let noted = try XCTUnwrap(sessions.first { $0.buyInTotal == 300 })
        XCTAssertEqual(noted.notes, multiLineNote)
        XCTAssertEqual(noted.cashOut, 650)
        XCTAssertEqual(noted.venueName, "Bellagio, Las Vegas")

        let freeroll = try XCTUnwrap(sessions.first { $0.buyInTotal == 0 })
        XCTAssertNil(freeroll.cashOut, "blank cash-out must stay nil, not become $0")
        XCTAssertEqual(freeroll.venueName, "Home Game")
    }

    @MainActor
    func testReimportSkipsAllRowsAsDuplicates() throws {
        let source = try makeInMemoryContainer()
        try populateSource(source.mainContext)
        let export = CSVExporter.exportCSV(from: source.mainContext)

        let url = try writeTempCSV(export.csvString)
        defer { try? FileManager.default.removeItem(at: url) }

        let destination = try makeInMemoryContainer()
        let first = CSVImporter.importCSV(from: url, into: destination.mainContext)
        XCTAssertEqual(first.cashSessionsCreated + first.tournamentsCreated, 3)

        let second = CSVImporter.importCSV(from: url, into: destination.mainContext)
        XCTAssertEqual(second.duplicatesSkipped, 3, "re-import must be idempotent")
        XCTAssertEqual(second.cashSessionsCreated, 0)
        XCTAssertEqual(second.tournamentsCreated, 0)

        XCTAssertEqual(try destination.mainContext.fetch(FetchDescriptor<CashSession>()).count, 2)
        XCTAssertEqual(try destination.mainContext.fetch(FetchDescriptor<Tournament>()).count, 1)
    }

    func testRFC4180ParserHandlesQuotedFields() {
        // NOTE: rows use LF endings (what CSVExporter emits). CRLF endings are
        // mis-parsed because Swift treats "\r\n" as a single Character that
        // matches neither the "\r" nor "\n" case — known implementation bug.
        let csv = "a,\"b,c\",\"line1\nline2\",\"He said \"\"hi\"\"\"\nd,e,f,g"
        let rows = CSVImporter.parseCSV(csv)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], ["a", "b,c", "line1\nline2", "He said \"hi\""])
        XCTAssertEqual(rows[1], ["d", "e", "f", "g"])
    }

    @MainActor
    func testImporterHandlesHandBuiltQuotedCSV() throws {
        let csv = "Date,Format,Variant,Stakes,Location,Buy-in ($),Cash-out ($),Profit/Loss ($),Duration (hours),Hourly Rate ($/hr),Notes\n"
            + "01/15/2026,Cash,NLH,1/3,\"Bellagio, Las Vegas\",300,650,350,4.00,87.50,"
            + "\"Line one, with comma\nline two \"\"quoted\"\"\""
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try makeInMemoryContainer()
        let result = CSVImporter.importCSV(from: url, into: container.mainContext)

        XCTAssertEqual(result.cashSessionsCreated, 1)
        XCTAssertEqual(result.rowsSkipped, 0)

        let session = try XCTUnwrap(
            try container.mainContext.fetch(FetchDescriptor<CashSession>()).first
        )
        XCTAssertEqual(session.venueName, "Bellagio, Las Vegas")
        XCTAssertEqual(session.notes, "Line one, with comma\nline two \"quoted\"")
        XCTAssertEqual(session.cashOut, 650)
    }
}

// MARK: - TweetComposer weighted length

final class TweetComposerTests: XCTestCase {

    func testPlainASCIICountsOnePerCharacter() {
        XCTAssertEqual(TweetComposer.weightedTweetLength(of: "hello world"), 11)
        XCTAssertEqual(TweetComposer.weightedTweetLength(of: ""), 0)
    }

    func testURLCountsAsFixed23() {
        let text = "check https://example.com/some/very/long/path/that/keeps/going"
        // "check " = 6, URL = flat 23 regardless of its real length.
        XCTAssertEqual(TweetComposer.weightedTweetLength(of: text), 29)
    }

    func testEmojiCountsAsTwo() {
        XCTAssertEqual(TweetComposer.weightedTweetLength(of: "🔥"), 2)
        XCTAssertEqual(TweetComposer.weightedTweetLength(of: "a🔥b"), 4)
        // Multi-scalar ZWJ family emoji is still a single weighted-2 grapheme.
        XCTAssertEqual(TweetComposer.weightedTweetLength(of: "👨‍👩‍👧‍👦"), 2)
    }

    func testCJKCountsAsTwo() {
        XCTAssertEqual(TweetComposer.weightedTweetLength(of: "ポーカー"), 8)
        XCTAssertEqual(TweetComposer.weightedTweetLength(of: "poker 撲克"), 10) // 6 + 2x2
    }

    func testRemainingCharacters() {
        XCTAssertEqual(TweetComposer.remainingCharacters(for: "hello"), 275)
        XCTAssertEqual(TweetComposer.remainingCharacters(for: ""), 280)
    }
}

// MARK: - Structure library

final class BlindStructureTemplateTests: XCTestCase {

    @MainActor
    func testLevelsRoundTripThroughJSONBlob() throws {
        let container = try makeInMemoryContainer()

        var l1 = BlindLevelCodable(from: ScannedBlindLevel(
            levelNumber: 1, smallBlind: 100, bigBlind: 200, ante: 200,
            durationMinutes: 30, isBreak: false, breakLabel: nil
        ))
        l1.ante = 200
        let breakLevel = BlindLevelCodable(from: ScannedBlindLevel(
            levelNumber: 2, smallBlind: 0, bigBlind: 0, ante: 0,
            durationMinutes: 15, isBreak: true, breakLabel: "Break"
        ))

        let template = BlindStructureTemplate(
            name: "WSOP $1,500 Freezeout",
            venueName: "Horseshoe",
            startingChips: 25_000,
            levels: [l1, breakLevel]
        )
        container.mainContext.insert(template)
        try container.mainContext.save()

        let decoded = template.levels
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].smallBlind, 100)
        XCTAssertEqual(decoded[0].bigBlind, 200)
        XCTAssertEqual(decoded[1].isBreak, true)
        XCTAssertEqual(decoded[1].breakLabel, "Break")
        XCTAssertEqual(template.playingLevelCount, 1, "breaks excluded from level count")

        // Conversion back to the scan pipeline's type keeps values intact.
        let scanned = decoded.map { $0.toScannedBlindLevel() }
        XCTAssertEqual(scanned[0].levelNumber, 1)
        XCTAssertEqual(scanned[0].ante, 200)
        XCTAssertEqual(scanned[1].durationMinutes, 15)
    }

    @MainActor
    func testSnapshotFromPersistedBlindLevel() throws {
        let container = try makeInMemoryContainer()
        let level = BlindLevel(levelNumber: 5, smallBlind: 400, bigBlind: 800, ante: 800, durationMinutes: 40)
        container.mainContext.insert(level)

        let codable = BlindLevelCodable(from: level)
        XCTAssertEqual(codable.levelNumber, 5)
        XCTAssertEqual(codable.smallBlind, 400)
        XCTAssertEqual(codable.bigBlind, 800)
        XCTAssertEqual(codable.ante, 800)
        XCTAssertEqual(codable.durationMinutes, 40)
        XCTAssertFalse(codable.isBreak)
    }
}

// MARK: - CSV line-ending regression

final class CSVLineEndingTests: XCTestCase {

    func testCRLFLineEndingsParseAsSeparateRows() {
        let csv = "a,b,c\r\n1,2,3\r\n4,5,6\r\n"
        let rows = CSVImporter.parseCSV(csv)

        XCTAssertEqual(rows.count, 3, "CRLF-terminated CSV (Excel style) must split into rows")
        XCTAssertEqual(rows[0], ["a", "b", "c"])
        XCTAssertEqual(rows[1], ["1", "2", "3"])
        XCTAssertEqual(rows[2], ["4", "5", "6"])
    }

    func testBareCRLineEndingsParseAsSeparateRows() {
        let rows = CSVImporter.parseCSV("a,b\r1,2\r")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1], ["1", "2"])
    }

    func testQuotedCRLFStaysInsideField() {
        let rows = CSVImporter.parseCSV("a,\"line1\r\nline2\",c\r\n")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0][1], "line1\r\nline2")
    }
}
