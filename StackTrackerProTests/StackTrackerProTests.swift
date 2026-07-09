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
        TournamentEvent.self,
        Hand.self,
        HandAction.self,
        HandStub.self,
        FadeNote.self,
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

// MARK: - WSOP structure sheet parsing

final class WSOPStructureParserTests: XCTestCase {

    private let scanner = PokerAtlasScanner.shared

    // Captured verbatim from the app's OCR pipeline (3x render + Vision)
    // run against the 2026 WSOP Main Event structure PDF. Two-column
    // layout: schedule text merges into structure rows.
    private let page1Lines = [
        "POKER",
        "HORSESHOE. A Paris",
        "LAS VEGAS LAS VEGAS",
        "2026 WORLD SERIES OF POKER",
        "EVENT #82: $10,000 SOP MAIN EVENT",
        "57TH NO-LIMIT HOLD'EM WORLD CHAMPIONSHIP (TELEVISED)",
        "THURSDAY - JULY 2; FRIDAY - JULY 3,",
        "SATURDAY - JULY 4, SUNDAY - JULY 5, 2026 AT 11 AM",
        "Starting Chips: 60,000 Day 3 - July 8, 2026 (Wednesday):",
        "Level Duration: 120 minutes 2:00 p.m. Star",
        "Late Registration: 7 levels (2 levels into July 6 & 7)",
        "Day 1A - July 2, 2026 (Thursday): 11:00 a.m. Start",
        "11:00 a.m. Start",
        "Play 5 levels",
        "Breaks TBA LEVEL BB ANTE BLINDS",
        "1 200 100-200",
        "Day 1B - July 3, 2026 (Friday): 2 300 200-300",
        "11:00 a.m. Start 3 400 200-400",
        "Play 5 levels 4 500 300-500",
        "Breaks TBA 5 600 300-600",
        "End of Days 1A, 1B, 1C, & 1D",
        "Day 1C - July 4, 2026 (Saturday): 6 800 400-800",
        "11:00 a.m. Start 7 1,000 500-1,000",
        "Play 5 levels 8 1,200 600-1,200",
        "Breaks TBA Remove 100 Chips",
        "9 1,500 1,000-1,500",
        "Day 1D - July 5, 2026 (Sunday): 10 2,000 1,000-2,000",
        "11:00 a.m. Start 11 2,500 1,000-2,500",
        "Play 5 levels 12 3,000 1,500-3,000",
        "Breaks TBA 4,000 2,000-4,000",
        "Remove 500 Chips",
        "Day 2A, 2B, & 2C - July 6, 2026 (Monday): 14 5,000 3,000-5,000",
        "Remaining players from Day 1A + 1B + 1C (combined) 6,000 3,000-6,000",
        "11:00 a.m. Start New entrants who have yet to enter any previous flight 16 8,000 4,000-8,000",
        "Play 5 levels 17 10,000 5,000-10,000",
        "Breaks TBA",
        "To register online, please visit: https://www.wsop.com/registration/"
    ]

    private let page2Lines = [
        "Day 6 - July 11, 2026 (Saturday): 46 8,000,000 4,000,000-8,000,000",
        "11:00 a.m. Start 47 10,000,000 5,000,000-10,000,000",
        "Play 5 levels",
        "Day 8 - July 13, 2026 (Monday):",
        "Michael Mizrachi - $10,000,000",
        "LEVEL ANTE BLINDS",
        "18 12,000 6,000-12,000",
        "Remove 1,000 Chips",
        "19 15,000 10,000-15,000",
        "20,000 10,000-20,000",
        "21 25,000 10,000-25,000",
        "30,000 15,000-30,000",
        "23 40,000 20,000-40,000",
        "24 50,000 25,000-50,000",
        "37 1,000,000",
        "44 5,000,000"
    ]

    func testParsesWSOPPage1WithMergedColumnsAndMissingLevelNumbers() {
        let levels = scanner.parseBlindLevels(from: page1Lines)

        XCTAssertEqual(levels.count, 17, "levels 1-17, no break rows, race-offs skipped")
        XCTAssertEqual(levels.first?.levelNumber, 1)
        XCTAssertEqual(levels.first?.smallBlind, 100)
        XCTAssertEqual(levels.first?.bigBlind, 200)
        XCTAssertEqual(levels.first?.ante, 200)
        XCTAssertEqual(levels.first?.durationMinutes, 120, "sheet-wide Level Duration applied")

        // Row merged with schedule text: "Day 1B - ... (Friday): 2 300 200-300"
        let l2 = levels.first { $0.levelNumber == 2 }
        XCTAssertEqual(l2?.smallBlind, 200)
        XCTAssertEqual(l2?.bigBlind, 300)

        // OCR dropped the "13": "4,000 2,000-4,000" must infer level 13.
        let l13 = levels.first { $0.levelNumber == 13 }
        XCTAssertEqual(l13?.smallBlind, 2_000)
        XCTAssertEqual(l13?.bigBlind, 4_000)
        XCTAssertEqual(l13?.ante, 4_000)

        // Same for level 15 ("6,000 3,000-6,000" merged into schedule text).
        let l15 = levels.first { $0.levelNumber == 15 }
        XCTAssertEqual(l15?.bigBlind, 6_000)

        XCTAssertEqual(levels.last?.levelNumber, 17)
        XCTAssertEqual(levels.last?.bigBlind, 10_000)
    }

    func testParsesWSOPPage2IncludingAnteOnlyRows() {
        let levels = scanner.parseBlindLevels(from: page2Lines)

        // 18, 19, 20 (inferred), 21, 22 (inferred), 23, 24, 37, 44, 46, 47
        XCTAssertEqual(levels.count, 11)
        XCTAssertEqual(levels.map(\.levelNumber), [18, 19, 20, 21, 22, 23, 24, 37, 44, 46, 47],
                       "sorted by level despite 46/47 appearing first in OCR order")

        let l20 = levels.first { $0.levelNumber == 20 }
        XCTAssertEqual(l20?.smallBlind, 10_000)
        XCTAssertEqual(l20?.bigBlind, 20_000)

        // Ante-only row: BB = BB ante, SB approximated as half.
        let l37 = levels.first { $0.levelNumber == 37 }
        XCTAssertEqual(l37?.bigBlind, 1_000_000)
        XCTAssertEqual(l37?.ante, 1_000_000)
        XCTAssertEqual(l37?.smallBlind, 500_000)

        // Merged with day text at the top of the page.
        let l47 = levels.first { $0.levelNumber == 47 }
        XCTAssertEqual(l47?.smallBlind, 5_000_000)
        XCTAssertEqual(l47?.bigBlind, 10_000_000)

        // No duration line on this page — sentinel awaiting normalization.
        XCTAssertEqual(levels.first?.durationMinutes, 0)
    }

    func testNormalizeDurationsPropagatesSheetDuration() {
        let page1 = scanner.parseBlindLevels(from: page1Lines)
        let page2 = scanner.parseBlindLevels(from: page2Lines)
        let normalized = scanner.normalizeDurations(page1 + page2)

        XCTAssertTrue(normalized.allSatisfy { $0.durationMinutes == 120 },
                      "page 2 rows inherit the duration stated on page 1")
    }

    func testPokerAtlasFormatUnaffectedByWSOPPath() {
        // A Poker Atlas-style table (no dash blinds) must not route through
        // the WSOP parser.
        let lines = [
            "Name Length SB BB Ante",
            "Level 1 30 100 200 200",
            "Level 2 30 200 300 300",
            "Break 15",
            "Level 3 30 200 400 400"
        ]
        let levels = scanner.parseBlindLevels(from: lines)

        XCTAssertEqual(levels.count, 4)
        XCTAssertEqual(levels.filter { !$0.isBreak }.count, 3)
        XCTAssertEqual(levels.first?.durationMinutes, 30)
        XCTAssertEqual(levels.first?.smallBlind, 100)
    }
}

// MARK: - Recap export

final class TournamentRecapExporterTests: XCTestCase {

    @MainActor
    func testMarkdownContainsAllSectionsAndData() throws {
        let container = try makeInMemoryContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext

        let t = Tournament(name: "25K GTD Saturday Special", buyIn: 250, entryFee: 195)
        context.insert(t)
        t.venueName = "Champions Club"
        t.startingChips = 30_000
        t.fieldSize = 120
        t.addOnAvailable = true
        t.addOnCost = 100
        t.addOnRake = 10
        t.addOnChips = 30_000
        t.addOnsCount = 65
        t.playerAddOnsUsed = 1

        let base = Date(timeIntervalSince1970: 1_780_000_000)
        t.actualStartDate = base
        t.endDate = base.addingTimeInterval(4 * 3600)
        t.statusRaw = "completed"
        t.finishPosition = 14
        t.payout = 0

        // Structure
        let level = BlindLevel(levelNumber: 1, smallBlind: 100, bigBlind: 200, ante: 200)
        level.tournament = t
        context.insert(level)

        // Timeline pieces, deliberately inserted out of order
        let laterStack = StackEntry(timestamp: base.addingTimeInterval(3600), chipCount: 60_000, blindLevelNumber: 2, currentSB: 200, currentBB: 300, currentAnte: 300)
        let earlyStack = StackEntry(timestamp: base.addingTimeInterval(60), chipCount: 30_000, blindLevelNumber: 1, currentSB: 100, currentBB: 200, currentAnte: 200)
        t.stackEntries = [laterStack, earlyStack]

        let event = TournamentEvent(type: .rebuy, intValue: 1, timestamp: base.addingTimeInterval(1800))
        t.events = [event]

        let note = HandNote(descriptionText: "Flopped a set vs the table captain", stackBefore: 45_000, stackAfter: nil, blindLevelNumber: 2, blindsDisplay: "200/300")
        note.timestamp = base.addingTimeInterval(2400)
        t.handNotes = [note]

        let message = ChatMessage(sender: .user, text: "60k now")
        message.timestamp = base.addingTimeInterval(3610)
        t.chatMessages = [message]

        let hand = Hand(heroPosition: .btn, heroCardsRaw: "As Kh",
                        levelNumber: 2, smallBlind: 200, bigBlind: 300, ante: 300,
                        heroStackChips: 55_000, playersRemaining: 100, tableSize: 9)
        hand.timestamp = base.addingTimeInterval(2500)
        hand.boardRaw = "Ah 7d 2c"
        hand.resultRaw = HandResult.won.rawValue
        hand.amountWon = 4200
        hand.tournament = t
        context.insert(hand)
        let act = HandAction(orderIndex: 0, street: .preflop, position: .btn,
                             actionType: .raise, amount: 900, isHero: true)
        act.hand = hand
        context.insert(act)

        let markdown = TournamentRecapExporter.markdown(for: t)

        // All sections present
        for heading in ["# Tournament Recap Data", "## Summary", "## Blind Structure",
                        "## Timeline", "## Stack Series (CSV)", "## Hand Notes", "## Chat Transcript"] {
            XCTAssertTrue(markdown.contains(heading), "missing section: \(heading)")
        }

        // Summary facts
        XCTAssertTrue(markdown.contains("Champions Club"))
        XCTAssertTrue(markdown.contains("| Entries | 120 |"))
        XCTAssertTrue(markdown.contains("| Add-ons (field / mine) | 65 / 1 |"))
        XCTAssertTrue(markdown.contains("| Total invested | $350 |"), "buy-in 250 + 1 add-on × 100")

        // CSV has both stack rows
        XCTAssertTrue(markdown.contains("timestamp,chips,level,small_blind,big_blind,ante,bb_count"))
        XCTAssertTrue(markdown.contains(",30000,1,100,200,200,"))
        XCTAssertTrue(markdown.contains(",60000,2,200,300,300,"))

        // Timeline is chronological: the 30k stack row precedes the rebuy,
        // which precedes the 60k stack row.
        let earlyRange = try XCTUnwrap(markdown.range(of: "Stack: 30,000"))
        let rebuyRange = try XCTUnwrap(markdown.range(of: "Rebuy / re-entry taken"))
        let lateRange = try XCTUnwrap(markdown.range(of: "Stack: 60,000"))
        XCTAssertLessThan(earlyRange.lowerBound, rebuyRange.lowerBound)
        XCTAssertLessThan(rebuyRange.lowerBound, lateRange.lowerBound)

        // Hand note and chat present
        XCTAssertTrue(markdown.contains("Flopped a set vs the table captain"))
        XCTAssertTrue(markdown.contains("**Player:** 60k now"))

        // Structured hands section
        XCTAssertTrue(markdown.contains("## Structured Hands"))
        XCTAssertTrue(markdown.contains("A♠ K♥"))
        XCTAssertTrue(markdown.contains("BTN raise 900"))
    }

    @MainActor
    func testWriteRecapFileProducesNamedMarkdownFile() throws {
        let container = try makeInMemoryContainer()
        defer { withExtendedLifetime(container) {} }
        let t = Tournament(name: "WSOP $1,500 Freezeout!", buyIn: 1500)
        container.mainContext.insert(t)

        let url = try TournamentRecapExporter.writeRecapFile(for: t)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.lastPathComponent, "WSOP-1-500-Freezeout-recap.md",
                       "non-alphanumerics collapsed into dashes")
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("# Tournament Recap Data"))
    }
}

// MARK: - Hand model

final class HandModelTests: XCTestCase {

    func testPlayingCardParsing() {
        XCTAssertEqual(PlayingCard("As")?.display, "A♠")
        XCTAssertEqual(PlayingCard("Th")?.display, "T♥")
        XCTAssertNil(PlayingCard("Zx"))
        XCTAssertNil(PlayingCard("A"))
        let cards = PlayingCard.parseList("As Kh 7d")
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(PlayingCard.joinList(cards), "As Kh 7d")
    }

    @MainActor
    func testHandPersistsWithActionsAndContext() throws {
        let container = try makeInMemoryContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext

        let t = Tournament(name: "Ultra Stack", buyIn: 600)
        context.insert(t)

        let hand = Hand(
            heroPosition: .btn,
            heroCardsRaw: "As Kh",
            levelNumber: 8, smallBlind: 600, bigBlind: 1200, ante: 1200,
            heroStackChips: 85_000, playersRemaining: 140, tableSize: 9
        )
        hand.boardRaw = "Ah 7d 2c"
        hand.resultRaw = HandResult.won.rawValue
        hand.potSize = 24_000
        hand.amountWon = 12_400
        hand.tournament = t
        context.insert(hand)

        let a1 = HandAction(orderIndex: 0, street: .preflop, position: .utg, actionType: .raise, amount: 3000, isHero: false)
        let a2 = HandAction(orderIndex: 1, street: .preflop, position: .btn, actionType: .raise, amount: 9000, isHero: true)
        a1.hand = hand; a2.hand = hand
        context.insert(a1); context.insert(a2)
        try context.save()

        XCTAssertEqual(t.sortedHands.count, 1)
        let saved = t.sortedHands[0]
        XCTAssertEqual(saved.heroCards.map(\.display), ["A♠", "K♥"])
        XCTAssertEqual(saved.board.count, 3)
        XCTAssertEqual(saved.sortedActions.map(\.orderIndex), [0, 1])
        XCTAssertEqual(saved.sortedActions[1].actionType, .raise)
        XCTAssertTrue(saved.sortedActions[1].isHero)
        XCTAssertEqual(saved.netResult, 12_400)
        XCTAssertEqual(saved.result, .won)
    }
}

// MARK: - Hand entry state machine

final class HandEntryModelTests: XCTestCase {

    @MainActor
    func testStageProgressionThroughFullHand() {
        let m = HandEntryModel()
        XCTAssertEqual(m.stage, .position)

        m.selectPosition(.btn)
        XCTAssertEqual(m.stage, .holeCards)
        XCTAssertEqual(m.actingPosition, .btn, "hero position preselected for actions")

        XCTAssertTrue(m.addCard(PlayingCard("As")!))
        XCTAssertEqual(m.stage, .holeCards, "still waiting for second card")
        XCTAssertTrue(m.addCard(PlayingCard("Kh")!))
        XCTAssertEqual(m.stage, .action(.preflop))

        XCTAssertFalse(m.addCard(PlayingCard("As")!), "dealt card rejected")
        XCTAssertTrue(m.isCardDealt(PlayingCard("As")!))

        m.addAction(.raise, amount: 3000)
        XCTAssertEqual(m.draftActions.count, 1)
        XCTAssertTrue(m.draftActions[0].isHero, "action at hero position is hero's")

        m.advanceStreet()
        XCTAssertEqual(m.stage, .boardCards(.flop))
        _ = m.addCard(PlayingCard("Ah")!)
        _ = m.addCard(PlayingCard("7d")!)
        XCTAssertEqual(m.stage, .boardCards(.flop))
        _ = m.addCard(PlayingCard("2c")!)
        XCTAssertEqual(m.stage, .action(.flop))

        m.advanceStreet()
        _ = m.addCard(PlayingCard("Ts")!)
        XCTAssertEqual(m.stage, .action(.turn))
        m.advanceStreet()
        _ = m.addCard(PlayingCard("3h")!)
        XCTAssertEqual(m.stage, .action(.river))

        m.finishHand()
        XCTAssertEqual(m.stage, .result)
    }

    @MainActor
    func testFinishFromPreflopSkipsBoard() {
        let m = HandEntryModel()
        m.selectPosition(.co)
        _ = m.addCard(PlayingCard("7s")!)
        _ = m.addCard(PlayingCard("2c")!)
        m.addAction(.fold)
        m.finishHand()
        XCTAssertEqual(m.stage, .result)
        XCTAssertEqual(m.result, .folded, "hero fold pre-selects Folded result")
    }

    @MainActor
    func testUndoRemovesLastInputPerStage() {
        let m = HandEntryModel()
        m.selectPosition(.sb)
        _ = m.addCard(PlayingCard("Qd")!)
        m.undo()
        XCTAssertEqual(m.heroCards.count, 0)
        XCTAssertFalse(m.isCardDealt(PlayingCard("Qd")!))
        m.undo()
        XCTAssertEqual(m.stage, .position, "undo past cards returns to position")
        XCTAssertNil(m.heroPosition)
    }

    @MainActor
    func testNonHeroActionAndPotEstimate() {
        let m = HandEntryModel()
        m.selectPosition(.bb)
        _ = m.addCard(PlayingCard("9c")!)
        _ = m.addCard(PlayingCard("9d")!)
        m.actingPosition = .utg
        m.addAction(.raise, amount: 600)
        XCTAssertFalse(m.draftActions[0].isHero)
        m.actingPosition = .bb
        m.addAction(.call, amount: 600)
        // pot = sb+bb+bbAnte + action amounts = 100+200+200 + 600+600
        XCTAssertEqual(m.potEstimate(sb: 100, bb: 200, ante: 200), 1700)
    }

    @MainActor
    func testSaveSnapshotsTournamentContext() throws {
        let container = try makeInMemoryContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let t = Tournament(name: "Test", buyIn: 250)
        context.insert(t)
        t.fieldSize = 200
        t.playersRemaining = 88
        let level = BlindLevel(levelNumber: 9, smallBlind: 1000, bigBlind: 1500, ante: 1500)
        level.tournament = t
        context.insert(level)
        t.currentBlindLevelNumber = 9
        let entry = StackEntry(chipCount: 42_000, blindLevelNumber: 9, currentSB: 1000, currentBB: 1500, currentAnte: 1500)
        entry.tournament = t
        context.insert(entry)

        let m = HandEntryModel()
        m.selectPosition(.hj)
        _ = m.addCard(PlayingCard("Js")!)
        _ = m.addCard(PlayingCard("Jd")!)
        m.addAction(.raise, amount: 3300)
        m.finishHand()
        m.result = .won
        m.amountWon = 5100
        m.selectedTags = ["value bet"]

        let hand = m.save(into: context, tournament: t, cashSession: nil, seatsDefault: 9)
        try context.save()

        XCTAssertEqual(hand.levelNumber, 9)
        XCTAssertEqual(hand.smallBlind, 1000)
        XCTAssertEqual(hand.bigBlind, 1500)
        XCTAssertEqual(hand.heroStackChips, 42_000)
        XCTAssertEqual(hand.playersRemaining, 88)
        XCTAssertEqual(hand.heroCardsRaw, "Js Jd")
        XCTAssertEqual(hand.sortedActions.count, 1)
        XCTAssertEqual(hand.tags, ["value bet"])
        XCTAssertEqual(t.sortedHands.count, 1)
    }
}

// MARK: - Tournament event timeline

final class TournamentEventTests: XCTestCase {

    @MainActor
    private func makeManagerAndTournament() throws -> (TournamentManager, Tournament, ModelContainer) {
        let container = try makeInMemoryContainer()
        let manager = TournamentManager()
        manager.setContext(container.mainContext)
        let t = Tournament(name: "Event Log", buyIn: 250)
        container.mainContext.insert(t)
        manager.startTournament(t)
        return (manager, t, container)
    }

    @MainActor
    func testRebuyLogsTimestampedEvent() throws {
        let (manager, t, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }

        manager.recordRebuy()
        manager.recordRebuy()

        let rebuys = t.sortedEvents.filter { $0.type == .rebuy }
        XCTAssertEqual(rebuys.count, 2)
        XCTAssertEqual(rebuys.last?.intValue, 2, "carries the running total")
    }

    @MainActor
    func testLevelChangeLoggedOnlyWhenLevelMoves() throws {
        let (manager, t, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }

        manager.setCurrentLevel(3)
        manager.setCurrentLevel(3) // no move — must not double-log

        let changes = t.sortedEvents.filter { $0.type == .levelChange }
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.intValue, 3)
    }

    @MainActor
    func testPauseResumeAndCompletionLogged() throws {
        let (manager, t, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }

        manager.pauseTournament()
        manager.resumeTournament()
        manager.completeTournament(position: 14, payout: 0)

        let types = t.sortedEvents.compactMap(\.type)
        XCTAssertTrue(types.contains(.pause))
        XCTAssertTrue(types.contains(.resume))
        XCTAssertTrue(types.contains(.completed))
        XCTAssertEqual(t.sortedEvents.last?.type, .completed)
        XCTAssertEqual(t.sortedEvents.last?.intValue, 14)
    }

    @MainActor
    func testUpdateStartingChipsRepairsInitialEntryAndMath() throws {
        let (manager, t, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }
        t.fieldSize = 100
        t.playersRemaining = 100
        t.payoutPercent = 12.5

        // startTournament recorded an initial entry at the (wrong) default.
        XCTAssertEqual(t.sortedStackEntries.first?.chipCount, t.startingChips)
        let wrongChips = t.startingChips

        manager.updateStartingChips(60_000)

        XCTAssertEqual(t.startingChips, 60_000)
        XCTAssertEqual(t.sortedStackEntries.first?.chipCount, 60_000,
                       "initial stack entry repaired so the graph starts right")
        XCTAssertEqual(t.totalChipsInPlay, 6_000_000)
        XCTAssertEqual(t.averageStack, 60_000)
        XCTAssertNotEqual(t.totalChipsInPlay, wrongChips * 100)

        let events = t.sortedEvents.filter { $0.type == .startingChipsCorrected }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.intValue, 60_000)
    }

    @MainActor
    func testUpdateStartingChipsNoOpWhenCompletedOrInvalid() throws {
        let (manager, t, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }
        let original = t.startingChips

        manager.updateStartingChips(0)
        XCTAssertEqual(t.startingChips, original, "non-positive rejected")

        manager.completeTournament(position: 10, payout: 0)
        manager.updateStartingChips(60_000)
        XCTAssertEqual(t.startingChips, original, "completed tournaments are read-only")
    }

    @MainActor
    func testAddOnCountChangesLogged() throws {
        let (manager, t, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }
        t.addOnAvailable = true
        t.addOnCost = 100

        manager.updateAddOns(fieldCount: 40, playerCount: 1)
        manager.updateAddOns(fieldCount: 40) // unchanged — no event

        let fieldEvents = t.sortedEvents.filter { $0.type == .addOnField }
        let playerEvents = t.sortedEvents.filter { $0.type == .addOnPlayer }
        XCTAssertEqual(fieldEvents.count, 1)
        XCTAssertEqual(fieldEvents.first?.intValue, 40)
        XCTAssertEqual(playerEvents.count, 1)
        XCTAssertEqual(playerEvents.first?.intValue, 1)
    }

    @MainActor
    func testCreateHandStubSnapshotsLiveContext() throws {
        let (manager, tournament, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }

        // Structure with a break row so display level != internal level:
        // internal 1–7 play, internal 8 is a break, internal 9–22 play.
        // Internal level 22 is therefore the 21st playing level (display L21).
        for n in 1...22 {
            if n == 8 {
                tournament.blindLevels?.append(
                    BlindLevel(levelNumber: n, smallBlind: 0, bigBlind: 0, isBreak: true))
            } else if n == 22 {
                tournament.blindLevels?.append(
                    BlindLevel(levelNumber: n, smallBlind: 10_000, bigBlind: 25_000, ante: 25_000))
            } else {
                tournament.blindLevels?.append(
                    BlindLevel(levelNumber: n, smallBlind: 100 * n, bigBlind: 200 * n))
            }
        }
        manager.updateBlinds(levelNumber: 22)
        manager.updateStack(chipCount: 390_000)
        manager.updateField(playersRemaining: 43)
        XCTAssertEqual(tournament.currentBlindLevelNumber, 22)
        XCTAssertEqual(tournament.currentDisplayLevel, 21)

        let stub = manager.createHandStub(holeCards: "KQs", quickResult: .won,
                                          quickVillain: .covered, origin: .manual)
        XCTAssertNotNil(stub)
        XCTAssertEqual(stub?.levelNumber, 21, "stub snapshots the user-facing display level")
        XCTAssertEqual(stub?.levelNumber, tournament.currentDisplayLevel)
        XCTAssertNotEqual(stub?.levelNumber, tournament.currentBlindLevelNumber,
                          "with breaks in the structure, display level must differ from internal")
        XCTAssertEqual(stub?.smallBlind, 10_000)
        XCTAssertEqual(stub?.bigBlind, 25_000)
        XCTAssertEqual(stub?.ante, 25_000)
        XCTAssertEqual(stub?.heroStackBefore, 390_000)
        XCTAssertEqual(stub?.playersRemaining, 43)
        XCTAssertEqual(tournament.pendingStubs.count, 1)

        manager.attachCards("Ah Kd", to: stub!)
        XCTAssertEqual(stub?.holeCards, "Ah Kd")

        manager.dismissStub(stub!)
        XCTAssertEqual(stub?.status, .dismissed)
        XCTAssertTrue(tournament.pendingStubs.isEmpty)
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

// MARK: - HandStub + FadeNote

final class HandStubTests: XCTestCase {

    @MainActor
    func testHandStubPersistsWithContextAndStatus() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let t = Tournament(name: "Stub Test", buyIn: 100)
        context.insert(t)

        let stub = HandStub(
            levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000, ante: 25_000,
            heroStackBefore: 390_000, playersRemaining: 43,
            holeCards: "KQs", origin: .manual
        )
        stub.quickResultRaw = QuickResult.won.rawValue
        stub.quickVillainRaw = QuickVillain.covered.rawValue
        stub.tournament = t
        context.insert(stub)

        let fade = FadeNote(intervalStart: .now, intervalEnd: .now, chipDelta: -340_000,
                            userExplanation: "blinds and a few small ones")
        fade.tournament = t
        context.insert(fade)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<HandStub>()).first
        XCTAssertEqual(fetched?.holeCards, "KQs")
        XCTAssertEqual(fetched?.origin, .manual)
        XCTAssertEqual(fetched?.status, .pending)
        XCTAssertEqual(fetched?.quickResult, .won)
        XCTAssertEqual(fetched?.quickVillain, .covered)
        XCTAssertEqual(fetched?.heroStackBefore, 390_000)
        XCTAssertEqual(t.pendingStubs.count, 1)
        XCTAssertEqual(t.fadeNotes?.count, 1)

        fetched?.setStatus(.dismissed)
        XCTAssertTrue(t.pendingStubs.isEmpty)
    }
}

// MARK: - HoleCardShorthand

final class HoleCardShorthandTests: XCTestCase {

    func testHoleCardShorthandNormalization() {
        // Exact
        XCTAssertEqual(HoleCardShorthand.normalize("AhKd"), "Ah Kd")
        XCTAssertEqual(HoleCardShorthand.normalize("ah kd"), "Ah Kd")
        XCTAssertEqual(HoleCardShorthand.normalize("KS QS"), "Ks Qs")
        // Suit-agnostic
        XCTAssertEqual(HoleCardShorthand.normalize("KQs"), "KQs")
        XCTAssertEqual(HoleCardShorthand.normalize("ako"), "AKo")
        XCTAssertEqual(HoleCardShorthand.normalize("99"), "99")
        XCTAssertEqual(HoleCardShorthand.normalize("kq"), "KQ")
        // Spoken-ish
        XCTAssertEqual(HoleCardShorthand.normalize("AK suited"), "AKs")
        XCTAssertEqual(HoleCardShorthand.normalize("ace king suited"), "AKs")
        XCTAssertEqual(HoleCardShorthand.normalize("pocket nines"), "99")
        XCTAssertEqual(HoleCardShorthand.normalize("queen jack offsuit"), "QJo")
        // Rejects
        XCTAssertNil(HoleCardShorthand.normalize("18000"))
        XCTAssertNil(HoleCardShorthand.normalize("level 12"))
        XCTAssertNil(HoleCardShorthand.normalize("no"))
        XCTAssertNil(HoleCardShorthand.normalize("As"))          // one card
        XCTAssertNil(HoleCardShorthand.normalize("AhAh"))        // duplicate
        XCTAssertNil(HoleCardShorthand.normalize("99s"))         // pair can't be suited
        XCTAssertNil(HoleCardShorthand.normalize("99o"))         // pair can't be offsuit
        XCTAssertNil(HoleCardShorthand.normalize("AAo"))         // pair can't be offsuit
        XCTAssertNil(HoleCardShorthand.normalize("got a bounty"))
    }

    func testHoleCardShorthandHelpers() {
        XCTAssertTrue(HoleCardShorthand.isExact("Ah Kd"))
        XCTAssertFalse(HoleCardShorthand.isExact("KQs"))
        XCTAssertEqual(HoleCardShorthand.exactCards("Ah Kd").map(\.raw), ["Ah", "Kd"])
        XCTAssertTrue(HoleCardShorthand.exactCards("KQs").isEmpty)
        XCTAssertEqual(HoleCardShorthand.display("Ah Kd"), "A♥ K♦")
        XCTAssertEqual(HoleCardShorthand.display("KQs"), "KQs")
    }
}

// MARK: - SwingDetector

final class SwingDetectorTests: XCTestCase {

    func testSwingDetectorThreshold() {
        // 390K → 985K at 25K BB: delta 595K vs max(78K, 200K) → swing
        XCTAssertTrue(SwingDetector.isSwing(previous: 390_000, new: 985_000,
                                            currentBB: 25_000, sensitivityPercent: 20))
        // Routine blind erosion: 390K → 380K → no
        XCTAssertFalse(SwingDetector.isSwing(previous: 390_000, new: 380_000,
                                             currentBB: 25_000, sensitivityPercent: 20))
        // Loss triggers too
        XCTAssertTrue(SwingDetector.isSwing(previous: 985_000, new: 760_000,
                                            currentBB: 25_000, sensitivityPercent: 20))
        // Off
        XCTAssertFalse(SwingDetector.isSwing(previous: 100_000, new: 500_000,
                                             currentBB: 1_000, sensitivityPercent: 0))
        // BB floor dominates for tiny stacks: 10K→13K at BB 1K = 3K < 8K
        XCTAssertFalse(SwingDetector.isSwing(previous: 10_000, new: 13_000,
                                             currentBB: 1_000, sensitivityPercent: 20))
    }

    func testSwingSuppression() {
        let now = Date()
        // >45 min since last update → ambiguous drift, suppress
        XCTAssertTrue(SwingDetector.shouldSuppress(
            previousEntryDate: now.addingTimeInterval(-46 * 60), now: now,
            latestPendingStubDate: nil))
        // Pending stub created 30s ago → duplicate, suppress
        XCTAssertTrue(SwingDetector.shouldSuppress(
            previousEntryDate: now.addingTimeInterval(-60), now: now,
            latestPendingStubDate: now.addingTimeInterval(-30)))
        // Clean case
        XCTAssertFalse(SwingDetector.shouldSuppress(
            previousEntryDate: now.addingTimeInterval(-10 * 60), now: now,
            latestPendingStubDate: now.addingTimeInterval(-10 * 60)))
    }
}

// MARK: - ChatManager

final class ChatManagerTests: XCTestCase {

    @MainActor
    private func makeManagerAndTournament() throws -> (TournamentManager, Tournament, ModelContainer) {
        let container = try makeInMemoryContainer()
        let manager = TournamentManager()
        manager.setContext(container.mainContext)
        let t = Tournament(name: "Chat Test", buyIn: 250)
        container.mainContext.insert(t)
        manager.startTournament(t)
        return (manager, t, container)
    }

    @MainActor
    func testChatStubShorthandCreatesStubAndAcks() async throws {
        let (manager, tournament, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }
        manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
        manager.updateStack(chipCount: 390_000)
        let chat = ChatManager(tournamentManager: manager)

        await chat.processUserMessage(text: "stub KQs")

        XCTAssertEqual(tournament.pendingStubs.count, 1)
        XCTAssertEqual(tournament.pendingStubs.first?.holeCards, "KQs")
        let lastAI = tournament.sortedChatMessages.last(where: { $0.sender == .ai })
        XCTAssertTrue(lastAI?.text.contains("Stub saved") ?? false)
        XCTAssertTrue(lastAI?.text.contains("KQs") ?? false)
    }

    @MainActor
    func testStubShorthandIgnoredWhenTournamentCompleted() async throws {
        let (manager, tournament, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }
        manager.completeTournament(position: 10, payout: 0)
        let chat = ChatManager(tournamentManager: manager)

        await chat.processUserMessage(text: "stub KQs")

        XCTAssertTrue(tournament.pendingStubs.isEmpty,
                      "completed tournaments are read-only — no stub created")
    }

    func testStubShorthandDetection() {
        XCTAssertEqual(ChatManager.stubShorthand(from: "stub KQs"), "KQs")
        XCTAssertEqual(ChatManager.stubShorthand(from: ". AhKd"), "Ah Kd")
        XCTAssertEqual(ChatManager.stubShorthand(from: "STUB 99"), "99")
        XCTAssertNil(ChatManager.stubShorthand(from: "stubborn opponent"))
        XCTAssertNil(ChatManager.stubShorthand(from: "18000"))
        XCTAssertNil(ChatManager.stubShorthand(from: "stub 18000"))
    }

    // MARK: - Swing Integration

    @MainActor
    func testSwingCreatesAutoStubAndPrompt() async throws {
        // The on-device AI parser is non-deterministic when available (some
        // simulator hosts have Apple Intelligence enabled); force the regex
        // parser so exact parsed-entity assertions below are stable.
        ChatManager.disableAIParsingForTesting = true
        defer { ChatManager.disableAIParsingForTesting = false }
        let (manager, tournament, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }
        manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
        let chat = ChatManager(tournamentManager: manager)
        await chat.processUserMessage(text: "390000")

        await chat.processUserMessage(text: "985000")
        XCTAssertEqual(tournament.pendingStubs.count, 1)
        XCTAssertEqual(tournament.pendingStubs.first?.origin, .swingDetected)
        let prompt = tournament.sortedChatMessages.last(where: { $0.sender == .ai })
        XCTAssertTrue(prompt?.text.contains("Big pot") ?? false)

        // Reply with cards → attaches
        await chat.processUserMessage(text: "AK suited")
        XCTAssertEqual(tournament.pendingStubs.first?.holeCards, "AKs")
    }

    @MainActor
    func testSwingPromptDismissedByUnrelatedMessage() async throws {
        ChatManager.disableAIParsingForTesting = true
        defer { ChatManager.disableAIParsingForTesting = false }
        let (manager, tournament, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }
        manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
        let chat = ChatManager(tournamentManager: manager)
        await chat.processUserMessage(text: "390000")
        await chat.processUserMessage(text: "985000")
        XCTAssertEqual(tournament.pendingStubs.count, 1)

        // Unrelated message → silent dismissal, message still processed
        await chat.processUserMessage(text: "120 players left")
        XCTAssertTrue(tournament.pendingStubs.isEmpty)   // dismissed, not pending
        XCTAssertEqual(tournament.playersRemaining, 120) // still applied
    }

    @MainActor
    func testNoSwingPromptForRoutineDrift() async throws {
        ChatManager.disableAIParsingForTesting = true
        defer { ChatManager.disableAIParsingForTesting = false }
        let (manager, tournament, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }
        manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
        let chat = ChatManager(tournamentManager: manager)
        await chat.processUserMessage(text: "390000")
        await chat.processUserMessage(text: "380000")
        XCTAssertTrue(tournament.pendingStubs.isEmpty)
    }

    @MainActor
    func testStubShorthandAnswersSwingPrompt() async throws {
        // Spec F2: "If the user replies with cards (any format), attach to the
        // auto-stub" — stub shorthand is a cards format, so it must attach to
        // the pending swing stub instead of creating a second manual stub.
        ChatManager.disableAIParsingForTesting = true
        defer { ChatManager.disableAIParsingForTesting = false }
        let (manager, tournament, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }
        manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
        let chat = ChatManager(tournamentManager: manager)
        await chat.processUserMessage(text: "390000")
        await chat.processUserMessage(text: "985000")
        XCTAssertEqual(tournament.pendingStubs.count, 1)

        // Reply with stub shorthand → attaches to the swing stub, no new stub.
        await chat.processUserMessage(text: "stub AKs")
        XCTAssertEqual(tournament.pendingStubs.count, 1)
        XCTAssertEqual(tournament.pendingStubs.first?.origin, .swingDetected)
        XCTAssertEqual(tournament.pendingStubs.first?.holeCards, "AKs")
    }
}
