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
        HandVillain.self,
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
                        "## Timeline", "## Stack Series (CSV)", "## Notes", "## Chat Transcript"] {
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

    @MainActor
    func testRecapIncludesStubsAndFadeNotes() throws {
        let container = try makeInMemoryContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let manager = TournamentManager()
        manager.setContext(context)
        let tournament = Tournament(name: "Stub Test", buyIn: 250)
        context.insert(tournament)
        manager.startTournament(tournament)

        manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
        manager.updateStack(chipCount: 390_000)
        let stub = manager.createHandStub(holeCards: "KQs", quickResult: .won,
                                          quickVillain: .covered, origin: .manual)
        XCTAssertNotNil(stub)
        let fade = FadeNote(intervalStart: .now, intervalEnd: .now, chipDelta: -340_000,
                            userExplanation: "card dead, paid blinds")
        fade.tournament = tournament
        context.insert(fade)

        let md = TournamentRecapExporter.markdown(for: tournament)
        XCTAssertTrue(md.contains("## Pending Hands"))
        XCTAssertTrue(md.contains("KQs"))
        XCTAssertTrue(md.contains("(unenriched)"))
        XCTAssertTrue(md.contains("card dead, paid blinds"))
    }

    /// A dictated-only hand (empty ledger, transcript in `notes`) must not
    /// fabricate a result into the recap — `resultRaw` still holds the model
    /// default ("Folded"), which the downstream recap AI would read as fact.
    /// The section carries the transcript and a "Dictated hand" descriptor
    /// instead; a structured hand in the same recap keeps its Result line.
    @MainActor
    func testRecapDictatedOnlyHandOmitsResultAndIncludesTranscript() throws {
        let container = try makeInMemoryContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let t = Tournament(name: "Dictation Test", buyIn: 100)
        context.insert(t)

        // Dictated-only hand: no actions, transcript in notes.
        let dictated = Hand(heroPosition: .btn, heroCardsRaw: "Ah Kd",
                            levelNumber: 5, smallBlind: 100, bigBlind: 200,
                            ante: 0, heroStackChips: 20_000)
        dictated.notes = "Opened the button, big blind jammed, I folded ace-king face up like a coward."
        dictated.tournament = t
        context.insert(dictated)

        // Structured hand alongside it keeps its Result line.
        let structured = Hand(heroPosition: .co, heroCardsRaw: "Qs Qd",
                              levelNumber: 5, smallBlind: 100, bigBlind: 200,
                              ante: 0, heroStackChips: 25_000)
        structured.resultRaw = HandResult.won.rawValue
        structured.amountWon = 1_200
        structured.tournament = t
        context.insert(structured)
        let act = HandAction(orderIndex: 0, street: .preflop, position: .co,
                             actionType: .raise, amount: 500, isHero: true)
        act.hand = structured
        context.insert(act)

        let md = TournamentRecapExporter.markdown(for: t)
        XCTAssertTrue(md.contains("Transcript: \(dictated.notes)"), "transcript must reach the recap")
        XCTAssertFalse(md.contains("Result: Folded"), "dictated-only hand must not fabricate a result")
        XCTAssertTrue(md.contains("Dictated hand"), "descriptor explains the absent structure")
        XCTAssertTrue(md.contains("Result: Won"), "structured hand keeps its result line")
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

    @MainActor
    func testHandVillainsPersistAndCascade() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let hand = Hand(heroPosition: .btn, heroCardsRaw: "Kh Kd")
        context.insert(hand)
        let v = HandVillain(orderIndex: 0, position: .utg, relativeStack: .coversHero)
        v.shownHolding = "9h Th"
        v.hand = hand
        context.insert(v)
        try context.save()

        XCTAssertEqual(hand.sortedVillains.count, 1)
        let first = try XCTUnwrap(hand.sortedVillains.first)
        XCTAssertEqual(first.position, .utg)
        XCTAssertEqual(first.relativeStack, .coversHero)
        context.delete(hand)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<HandVillain>()).count, 0)
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
        // The stub records the hand's real starting stack (390K, pre-pot) and
        // the post-pot stack (985K) — not the now-stale latestStack (985K) for
        // both, which the old snapshot-latestStack path produced.
        XCTAssertEqual(tournament.pendingStubs.first?.heroStackBefore, 390_000)
        XCTAssertEqual(tournament.pendingStubs.first?.heroStackAfter, 985_000)
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

    // MARK: - Break Debrief

    @MainActor
    func testDebriefFindsUnexplainedGapsLargestFirst() throws {
        let (manager, tournament, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }
        manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
        // Three updates: 985K → 700K (−285K, unexplained), 700K → 450K (−250K, unexplained).
        // (8×BB = 200,000 is the swing floor at this level, so both deltas clear it —
        // unlike the smaller −115K drift used elsewhere, which sits below the floor.)
        manager.updateStack(chipCount: 985_000)
        manager.updateStack(chipCount: 700_000)
        manager.updateStack(chipCount: 450_000)

        // Back-date the first two entries so the ±10-minute explain-padding
        // windows around each interval don't overlap — a stub created "now"
        // (below) should only fall inside the most recent interval's window.
        let entryA = tournament.stackEntries?.first { $0.chipCount == 985_000 }
        let entryB = tournament.stackEntries?.first { $0.chipCount == 700_000 }
        entryA?.timestamp = Date.now.addingTimeInterval(-40 * 60)
        entryB?.timestamp = Date.now.addingTimeInterval(-20 * 60)

        let gaps = BreakDebriefEngine.unexplainedGaps(for: tournament, since: nil,
                                                      sensitivityPercent: 20, maxCount: 3)
        // Guard before indexing: XCTAssertEqual doesn't halt on failure, and
        // out-of-bounds indexing would crash the whole suite.
        guard gaps.count == 2 else {
            XCTFail("expected 2 gaps, got \(gaps.count): \(gaps)"); return
        }
        XCTAssertEqual(gaps[0].delta, -285_000)   // largest first
        XCTAssertEqual(gaps[1].delta, -250_000)

        // A stub created now "explains" the most recent interval only
        manager.createHandStub(holeCards: "KQs", origin: .manual)
        let after = BreakDebriefEngine.unexplainedGaps(for: tournament, since: nil,
                                                       sensitivityPercent: 20, maxCount: 3)
        XCTAssertEqual(after.count, 1)
        let remaining = try XCTUnwrap(after.first)
        XCTAssertEqual(remaining.delta, -285_000)
    }

    @MainActor
    func testDebriefFlowRecordsFadeNote() async throws {
        ChatManager.disableAIParsingForTesting = true
        defer { ChatManager.disableAIParsingForTesting = false }
        let (manager, tournament, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }
        manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
        manager.updateStack(chipCount: 985_000)
        manager.updateStack(chipCount: 760_000)
        let chat = ChatManager(tournamentManager: manager)

        chat.runBreakDebrief()
        XCTAssertTrue(tournament.sortedChatMessages.last?.text.contains("dropped 225,000") ?? false)

        await chat.processUserMessage(text: "blinds and a few small ones")
        XCTAssertEqual(tournament.fadeNotes?.count, 1)
        XCTAssertEqual(tournament.fadeNotes?.first?.chipDelta, -225_000)
        // Once per break:
        chat.runBreakDebrief()
        XCTAssertEqual(tournament.sortedChatMessages.filter { $0.text.contains("debrief") }.count, 1)
    }

    @MainActor
    func testFadeNoteExplainsGapAfterLaterDefer() async throws {
        // Regression: a FadeNote must count as an "explainer" — after answering
        // one gap with freeform text and deferring the rest with "later"
        // (which resets lastDebriefAt so the next break recomputes over full
        // history), the FadeNote-explained gap must NOT be re-asked while the
        // deferred one still is.
        ChatManager.disableAIParsingForTesting = true
        defer { ChatManager.disableAIParsingForTesting = false }
        let (manager, tournament, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }
        manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
        // Two swings separated by a non-swing drift entry so the gaps don't
        // share a boundary timestamp (a shared boundary would let one gap's
        // FadeNote fall inside the other's ±10-min padding window).
        manager.updateStack(chipCount: 985_000)   // A
        manager.updateStack(chipCount: 700_000)   // B: A→B −285K (swing)
        manager.updateStack(chipCount: 690_000)   // C: B→C −10K (drift, not a swing)
        manager.updateStack(chipCount: 440_000)   // D: C→D −250K (swing)
        let entryA = tournament.stackEntries?.first { $0.chipCount == 985_000 }
        let entryB = tournament.stackEntries?.first { $0.chipCount == 700_000 }
        let entryC = tournament.stackEntries?.first { $0.chipCount == 690_000 }
        entryA?.timestamp = Date.now.addingTimeInterval(-60 * 60)
        entryB?.timestamp = Date.now.addingTimeInterval(-40 * 60)
        entryC?.timestamp = Date.now.addingTimeInterval(-25 * 60)
        let chat = ChatManager(tournamentManager: manager)

        chat.runBreakDebrief()
        XCTAssertTrue(tournament.sortedChatMessages.last?.text.contains("dropped 285,000") ?? false)

        // Freeform answer → FadeNote for the −285K gap; next question follows.
        await chat.processUserMessage(text: "card dead, bled blinds all level")
        XCTAssertEqual(tournament.fadeNotes?.count, 1)
        XCTAssertEqual(tournament.fadeNotes?.first?.chipDelta, -285_000)
        XCTAssertTrue(tournament.sortedChatMessages.last?.text.contains("dropped 250,000") ?? false)

        // Defer the rest → lastDebriefAt reset, full history recomputed next time.
        await chat.processUserMessage(text: "later")
        XCTAssertNil(tournament.lastDebriefAt)

        // The FadeNote-explained gap is gone; the deferred one remains.
        let gaps = BreakDebriefEngine.unexplainedGaps(for: tournament, since: nil,
                                                      sensitivityPercent: 20, maxCount: 3)
        XCTAssertEqual(gaps.count, 1, "unexpected gaps: \(gaps)")
        let remaining = try XCTUnwrap(gaps.first)
        XCTAssertEqual(remaining.delta, -250_000)
    }

    @MainActor
    func testDebriefCardsStubSnapshotsGapStartStack() async throws {
        ChatManager.disableAIParsingForTesting = true
        defer { ChatManager.disableAIParsingForTesting = false }
        let (manager, tournament, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }
        manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
        manager.updateStack(chipCount: 985_000)   // gap start
        manager.updateStack(chipCount: 760_000)   // gap end (−225K swing)
        let chat = ChatManager(tournamentManager: manager)

        chat.runBreakDebrief()
        // Answer with cards → the stub snapshots the gap's STARTING stack (985K),
        // not the mid-break latestStack (760K).
        await chat.processUserMessage(text: "KQs")
        let stub = try XCTUnwrap(tournament.pendingStubs.first)
        XCTAssertEqual(stub.origin, .breakDebrief)
        XCTAssertEqual(stub.heroStackBefore, 985_000)
    }

    // MARK: - Break button vs. outstanding swing prompt (I2)

    @MainActor
    func testBreakDebriefDismissesOutstandingSwingPrompt() async throws {
        ChatManager.disableAIParsingForTesting = true
        defer { ChatManager.disableAIParsingForTesting = false }
        let (manager, tournament, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }
        manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
        let chat = ChatManager(tournamentManager: manager)
        await chat.processUserMessage(text: "390000")
        await chat.processUserMessage(text: "985000")
        let swingStub = try XCTUnwrap(chat.pendingSwingStub)
        XCTAssertEqual(swingStub.origin, .swingDetected)

        // Break button while the swing prompt is still live: it is dismissed and
        // the reference cleared, leaving only the debrief question outstanding.
        chat.runBreakDebrief()
        XCTAssertNil(chat.pendingSwingStub)
        XCTAssertEqual(swingStub.status, .dismissed)

        // A cards reply now answers the DEBRIEF (its gap resurfaced once the
        // swing stub stopped counting as an explainer), creating a breakDebrief
        // stub — it does not attach to the old swing stub.
        await chat.processUserMessage(text: "KQs")
        let breakStub = tournament.handStubs?.first { $0.origin == .breakDebrief }
        XCTAssertEqual(breakStub?.holeCards, "KQs")
        XCTAssertEqual(swingStub.holeCards, "", "swing stub must not receive the debrief reply")
    }

    // MARK: - Conversation state across tournament switch (I3)

    @MainActor
    func testConversationStateResetsOnTournamentSwitch() async throws {
        ChatManager.disableAIParsingForTesting = true
        defer { ChatManager.disableAIParsingForTesting = false }
        let (manager, tournamentA, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }
        manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
        let chat = ChatManager(tournamentManager: manager)
        await chat.processUserMessage(text: "390000")
        await chat.processUserMessage(text: "985000")
        let stubA = try XCTUnwrap(chat.pendingSwingStub)
        XCTAssertEqual(tournamentA.pendingStubs.count, 1)

        // Switch the active tournament to B.
        let tournamentB = Tournament(name: "Second", buyIn: 100)
        container.mainContext.insert(tournamentB)
        manager.startTournament(tournamentB)

        // A cards-like reply now belongs to B — the stale swing prompt for A
        // must be dropped, not answered against B.
        await chat.processUserMessage(text: "AK suited")

        XCTAssertNil(chat.pendingSwingStub)
        XCTAssertEqual(stubA.holeCards, "", "A's swing stub must not receive B's reply")
        XCTAssertEqual(stubA.status, .pending, "A's stub is left untouched, not dismissed")
        XCTAssertTrue(tournamentB.handStubs?.isEmpty ?? true, "B has no stubs")
    }

    // MARK: - Debrief all-clear vs. silent auto-trigger (F7)

    @MainActor
    func testOnBreakAnnouncesAllClearWhenNoGaps() async throws {
        // Explicit "on break" must never dead-end at the ack: with zero
        // unexplained gaps the user gets an all-clear instead of silence.
        ChatManager.disableAIParsingForTesting = true
        defer { ChatManager.disableAIParsingForTesting = false }
        let (manager, tournament, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }
        manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
        manager.updateStack(chipCount: 500_000)   // single update → no intervals
        let chat = ChatManager(tournamentManager: manager)

        await chat.processUserMessage(text: "on break")

        let aiTexts = tournament.sortedChatMessages.filter { $0.sender == .ai }.map(\.text)
        XCTAssertTrue(aiTexts.contains { $0.contains("let's debrief") },
                      "ack bubble missing: \(aiTexts)")
        XCTAssertTrue(aiTexts.contains { $0.contains("all your swings are covered") },
                      "all-clear bubble missing: \(aiTexts)")
        XCTAssertNil(chat.activeDebriefGap, "no question should be pending when clear")
    }

    // MARK: - Debrief while paused (F12)

    @MainActor
    func testOnBreakDebriefsWhilePausedTournament() async throws {
        // Pausing the tracker for the break is natural; the old .active-only
        // guard in runBreakDebrief made "on break" ack ("let's debrief") and
        // then go silent. Paused tournaments must debrief exactly like active
        // ones, including the downstream mutations (stub creation on a cards
        // reply — mutableTournament only blocks .completed).
        ChatManager.disableAIParsingForTesting = true
        defer { ChatManager.disableAIParsingForTesting = false }
        let (manager, tournament, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }
        manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
        manager.updateStack(chipCount: 985_000)
        manager.updateStack(chipCount: 760_000)   // −225K unexplained gap
        manager.pauseTournament()
        XCTAssertEqual(tournament.status, .paused)
        let chat = ChatManager(tournamentManager: manager)

        await chat.processUserMessage(text: "on break")

        let aiTexts = tournament.sortedChatMessages.filter { $0.sender == .ai }.map(\.text)
        XCTAssertTrue(aiTexts.contains { $0.contains("let's debrief") },
                      "ack bubble missing: \(aiTexts)")
        XCTAssertTrue(aiTexts.contains { $0.contains("dropped 225,000") },
                      "debrief question missing while paused: \(aiTexts)")
        XCTAssertNotNil(chat.activeDebriefGap)

        // The cards reply must still create the breakDebrief stub while paused.
        await chat.processUserMessage(text: "KQs")
        let stub = try XCTUnwrap(tournament.pendingStubs.first)
        XCTAssertEqual(stub.origin, .breakDebrief)
        XCTAssertEqual(stub.heroStackBefore, 985_000)
    }

    @MainActor
    func testAutoDebriefStaysSilentWhenClear() throws {
        // The BreakTimerSheet auto-trigger path (default announceWhenClear:
        // false) must not add any chat message when there's nothing to ask.
        let (manager, tournament, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }
        manager.updateBlinds(levelNumber: 21, sb: 10_000, bb: 25_000, ante: 25_000)
        manager.updateStack(chipCount: 500_000)   // single update → no intervals
        let chat = ChatManager(tournamentManager: manager)
        let messagesBefore = tournament.chatMessages?.count ?? 0

        chat.runBreakDebrief()

        XCTAssertEqual(tournament.chatMessages?.count ?? 0, messagesBefore,
                       "silent auto-trigger must not append messages when clear")
        XCTAssertNil(chat.activeDebriefGap)
    }

    // MARK: - Fallback mentions hand logging (F8)

    @MainActor
    func testFallbackMentionsStubShorthand() throws {
        let (_, tournament, container) = try makeManagerAndTournament()
        defer { withExtendedLifetime(container) {} }

        let fallback = ResponseEngine.shared.generateResponse(entities: ParsedEntities(),
                                                              tournament: tournament)
        XCTAssertTrue(fallback.contains("stub AsKc"),
                      "fallback must teach the stub shorthand: \(fallback)")
    }
}

final class PokerHandEvaluatorTests: XCTestCase {
    private func score(_ s: String) throws -> PokerHandEvaluator.Score {
        try XCTUnwrap(PokerHandEvaluator.bestScore(PlayingCard.parseList(s)))
    }

    func testEvaluatorRanksCategories() throws {
        XCTAssertGreaterThan(try score("Ah Kh Qh Jh Th"), try score("As Ad Ac Ah Kd"))   // royal > quads
        XCTAssertGreaterThan(try score("As Ad Ac Kh Kd"), try score("As Ad Ac Kh Qd"))   // boat > trips
        XCTAssertGreaterThan(try score("2h 7h 9h Jh Kh"), try score("As Ks Qs Jd 9c"))   // flush > high card
        XCTAssertGreaterThan(try score("Ah 2d 3c 4s 5h"), try score("As Ad Kc Qh Jd"))   // wheel > pair
        XCTAssertEqual(try score("Ah Kd Qc Js Th"), try score("Ad Kh Qs Jc Td"))          // same straight
        // 7-card: board pairs the best hand
        let sevenCard = try XCTUnwrap(
            PokerHandEvaluator.bestScore(PlayingCard.parseList("Kh Kd Jh 8h 4d 2c 2s")))
        XCTAssertEqual(sevenCard.category, 2)  // two pair
    }

    func testHoldemWinnersKKvs9T() {
        // Event #86 reference hand: KK vs 9T on a J-8-4-2-3 board → KK's overpair holds
        // (NOTE: the brief's original board card was "Qs", but Jh-8h-...-9h-Th combine into
        // an 8-9-T-J-Q straight for the villain, which would actually beat KK's pair outright —
        // a genuine poker-math bug in the reference test. Swapped the case card to "3s" so the
        // scenario matches its stated outcome: no straight completes, and KK's pair wins clean.)
        let hero = UUID(), villain = UUID()
        let winners = PokerHandEvaluator.holdemWinners(
            board: PlayingCard.parseList("Jh 8h 4d 2c 3s"),
            holdings: [(hero, PlayingCard.parseList("Kh Kd")),
                       (villain, PlayingCard.parseList("9h Th"))])
        XCTAssertEqual(winners, [hero])
        // Chop: same straight
        let a = UUID(), b = UUID()
        let chop = PokerHandEvaluator.holdemWinners(
            board: PlayingCard.parseList("9h Th Jc Qs Kd"),
            holdings: [(a, PlayingCard.parseList("2h 3d")), (b, PlayingCard.parseList("4c 5s"))])
        XCTAssertEqual(Set(chop), Set([a, b]))
    }

    // MARK: - Extra edge cases

    func testQuadsVsQuadsKickerBreaksTie() throws {
        // Both hold quad aces on a paired board; kicker (K vs Q) decides.
        XCTAssertGreaterThan(try score("Ah Ad As Ac Kh"), try score("Ah Ad As Ac Qh"))
    }

    func testFlushTiebreaksOnHighCardsInOrder() throws {
        // Same suit, top card decides even though both are "just a flush".
        XCTAssertGreaterThan(try score("Ah Kh 9h 5h 2h"), try score("Ah Qh Jh 8h 3h"))
        // Second card decides when the top card matches.
        XCTAssertGreaterThan(try score("Ah Kh 9h 5h 2h"), try score("Ah Jh Th 8h 4h"))
    }

    func testAceHighStraightBeatsKingHighStraight() throws {
        XCTAssertGreaterThan(try score("Ah Kd Qc Js Td"), try score("Kh Qd Jc Ts 9d"))
    }

    func testWheelStraightIsLowestStraight() throws {
        // A-2-3-4-5 ("the wheel") plays the 5 as its high card, so it loses to 6-high straight.
        let wheel = try score("Ah 2d 3c 4s 5h")
        let sixHigh = try score("2h 3d 4c 5s 6h")
        XCTAssertEqual(wheel.category, 4)
        XCTAssertEqual(sixHigh.category, 4)
        XCTAssertGreaterThan(sixHigh, wheel)
    }

    func testTwoPairKickerBreaksTie() throws {
        // Same two pair (KK, 88); the fifth card (kicker) decides.
        XCTAssertGreaterThan(try score("Kh Kd 8h 8c Ah"), try score("Ks Kc 8s 8d Qd"))
    }

    func testFullHouseTripsRankDecidesOverPair() throws {
        // Trip rank outranks the pair rank when comparing two boats.
        XCTAssertGreaterThan(try score("Kh Kd Kc 2h 2d"), try score("Qh Qd Qc Ah Ad"))
    }

    func testBestScoreRejectsInvalidCardCounts() {
        XCTAssertNil(PokerHandEvaluator.bestScore(PlayingCard.parseList("Ah Kd Qc Js")))
        XCTAssertNil(PokerHandEvaluator.bestScore(
            PlayingCard.parseList("Ah Kd Qc Js Th 9c 8d 7h")))
    }

    func testBestScoreRejectsDuplicateCards() {
        XCTAssertNil(PokerHandEvaluator.bestScore(PlayingCard.parseList("Ah Ah Kd Qc Jh")))
    }

    func testHoldemWinnersReturnsEmptyForMalformedInput() {
        let hero = UUID()
        // Board must be exactly 5 cards.
        XCTAssertEqual(PokerHandEvaluator.holdemWinners(
            board: PlayingCard.parseList("Jh 8h 4d 2c"),
            holdings: [(hero, PlayingCard.parseList("Kh Kd"))]), [])
    }
}

// MARK: - HandCaptureModel (Task 12)

@MainActor
final class HandCaptureModelTests: XCTestCase {

    // MARK: Brief contract tests

    func testCaptureTurnOrderAndPot() throws {
        let model = HandCaptureModel(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                                     ante: 25_000, heroCardCount: 2, heroStackBefore: 390_000)
        model.heroPosition = .btn
        for c in PlayingCard.parseList("Kh Kd") { XCTAssertTrue(model.addCard(c)) }
        model.addVillain(position: .utg, relative: .coversHero, approxStack: 0)
        guard let utg = model.villains.first?.id else { return XCTFail("no villain") }

        // Preflop: UTG acts first (hero BTN, villain UTG; blinds are dead)
        XCTAssertEqual(model.participantToAct, .villain(utg))
        model.add(action: .raise, toAmount: 75_000)
        XCTAssertEqual(model.participantToAct, .hero)
        XCTAssertEqual(model.currentBet, 75_000)
        model.add(action: .call, toAmount: 0)

        // Street closed → flop needs 3 cards. Pot: ante+sb+bb dead (60K) + 150K
        XCTAssertEqual(model.boardCardsNeeded, 3)
        XCTAssertEqual(model.pot, 25_000 + 10_000 + 25_000 + 150_000)
        for c in PlayingCard.parseList("Jh 8h 4d") { XCTAssertTrue(model.addBoardCard(c)) }
        XCTAssertEqual(model.currentStreet, .flop)
        // Postflop: UTG first again (no SB/BB participants)
        XCTAssertEqual(model.participantToAct, .villain(utg))

        // Undo rewinds the board card and street state
        model.undoLast()
        XCTAssertEqual(model.boardCardsNeeded, 1)
        XCTAssertEqual(model.board.count, 2)
    }

    func testCaptureFoldEndsHand() throws {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 200, heroCardCount: 2, heroStackBefore: 40_000)
        model.heroPosition = .co
        for c in PlayingCard.parseList("As Kd") { _ = model.addCard(c) }
        model.addVillain(position: .bb, relative: .shorter, approxStack: 0)
        // Hero (CO) first preflop; BB already has 200 committed
        XCTAssertEqual(model.participantToAct, .hero)
        model.add(action: .raise, toAmount: 500)
        model.add(action: .fold, toAmount: 0)     // BB folds
        XCTAssertTrue(model.isHandOver)
        // Pot: ante 200 + sb dead 100 + bb 200 + hero 500 = 1000
        XCTAssertEqual(model.pot, 1000)
    }

    // MARK: Additional coverage

    /// Postflop turn order with an SB participant: action starts at SB, then BB,
    /// then wraps to the later positions.
    func testThreeWayPostflopOrderStartsAtSB() throws {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 20_000)
        model.heroPosition = .btn
        for c in PlayingCard.parseList("Ah Ad") { _ = model.addCard(c) }
        model.addVillain(position: .sb, relative: .similar, approxStack: 0)
        model.addVillain(position: .bb, relative: .coversHero, approxStack: 0)
        guard let sb = model.villains.first(where: { $0.position == .sb })?.id,
              let bb = model.villains.first(where: { $0.position == .bb })?.id else {
            return XCTFail("missing villains")
        }
        // Preflop: BTN (hero) acts first (first after BB, wrapping).
        XCTAssertEqual(model.participantToAct, .hero)
        model.add(action: .call, toAmount: 0)       // hero limps 200
        XCTAssertEqual(model.participantToAct, .villain(sb))
        model.add(action: .call, toAmount: 0)       // SB completes to 200
        XCTAssertEqual(model.participantToAct, .villain(bb))
        model.add(action: .check, toAmount: 0)      // BB checks option → close
        XCTAssertEqual(model.boardCardsNeeded, 3)
        for c in PlayingCard.parseList("2c 7d 9s") { XCTAssertTrue(model.addBoardCard(c)) }
        XCTAssertEqual(model.currentStreet, .flop)
        // Postflop: SB first.
        XCTAssertEqual(model.participantToAct, .villain(sb))
        // Pot = sb100 + bb200 dead? both are participants; committed preflop
        // hero200 + sb200 + bb200 = 600 (ante 0).
        XCTAssertEqual(model.pot, 600)
    }

    /// Check-check closes a postflop street.
    func testCheckCheckClosesStreet() throws {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 20_000)
        model.heroPosition = .btn
        for c in PlayingCard.parseList("Ah Ad") { _ = model.addCard(c) }
        model.addVillain(position: .co, relative: .similar, approxStack: 0)
        guard let co = model.villains.first?.id else { return XCTFail("no villain") }
        // Preflop: CO acts first, both call to close (no BB participant).
        XCTAssertEqual(model.participantToAct, .villain(co))
        model.add(action: .call, toAmount: 0)       // CO calls the big blind
        model.add(action: .call, toAmount: 0)       // hero (BTN) calls
        XCTAssertEqual(model.boardCardsNeeded, 3)
        for c in PlayingCard.parseList("2c 7d 9s") { XCTAssertTrue(model.addBoardCard(c)) }
        XCTAssertEqual(model.currentStreet, .flop)
        // Flop: both check → street closes, turn needs 1.
        model.add(action: .check, toAmount: 0)
        XCTAssertEqual(model.boardCardsNeeded, 0)   // one check, other still to act
        model.add(action: .check, toAmount: 0)
        XCTAssertEqual(model.boardCardsNeeded, 1)
        XCTAssertTrue(model.legalActions.isEmpty)   // awaiting board
    }

    /// A short all-in below the current bet still closes the street and the
    /// remaining board runs out to the river.
    func testShortAllInRunsOutBoard() throws {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 20_000)
        model.heroPosition = .co
        for c in PlayingCard.parseList("Ah Ad") { _ = model.addCard(c) }
        model.addVillain(position: .bb, relative: .shorter, approxStack: 300)
        guard let bb = model.villains.first?.id else { return XCTFail("no villain") }
        XCTAssertEqual(model.participantToAct, .hero)
        model.add(action: .raise, toAmount: 500)          // hero opens 500
        XCTAssertEqual(model.participantToAct, .villain(bb))
        model.add(action: .allIn, toAmount: 300)          // BB jams short for 300 total
        // Hero already committed 500 (> 300): nothing to call, street closes.
        XCTAssertEqual(model.boardCardsNeeded, 3)
        XCTAssertFalse(model.isHandOver)
        for c in PlayingCard.parseList("2c 7d 9s") { XCTAssertTrue(model.addBoardCard(c)) }
        // All remaining players all-in/uncontested → turn then river requested.
        XCTAssertEqual(model.boardCardsNeeded, 1)
        XCTAssertTrue(model.addBoardCard(PlayingCard("Ts")!))
        XCTAssertEqual(model.boardCardsNeeded, 1)
        XCTAssertTrue(model.addBoardCard(PlayingCard("3h")!))
        XCTAssertEqual(model.board.count, 5)
        XCTAssertTrue(model.isHandOver)
        // Pot: sb100 dead + bb participant present + hero 500 + bb 300 = 900.
        XCTAssertEqual(model.pot, 100 + 500 + 300)
    }

    /// Legal actions reflect the betting state.
    func testLegalActions() throws {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 20_000)
        model.heroPosition = .btn
        for c in PlayingCard.parseList("Ah Ad") { _ = model.addCard(c) }
        model.addVillain(position: .co, relative: .similar, approxStack: 0)
        // Preflop, CO faces the big blind (currentBet 200 > 0 committed).
        XCTAssertEqual(model.legalActions, [.fold, .call, .raise, .allIn])
        model.add(action: .call, toAmount: 0)              // CO calls
        model.add(action: .call, toAmount: 0)              // hero (BTN) calls to close (no BB participant)
        XCTAssertEqual(model.boardCardsNeeded, 3)
        for c in PlayingCard.parseList("2c 7d 9s") { _ = model.addBoardCard(c) }
        // Flop, first to act facing no bet.
        XCTAssertEqual(model.legalActions, [.fold, .check, .bet, .allIn])
    }

    /// Undo and truncate both recompute state deterministically via replay.
    func testUndoTruncateReplayDeterminism() throws {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 20_000)
        model.heroPosition = .btn
        for c in PlayingCard.parseList("Ah Ad") { _ = model.addCard(c) }
        model.addVillain(position: .utg, relative: .coversHero, approxStack: 0)
        model.add(action: .raise, toAmount: 600)           // UTG raise (ledger 0)
        model.add(action: .call, toAmount: 0)              // hero call (ledger 1)
        XCTAssertEqual(model.ledger.count, 2)
        XCTAssertEqual(model.boardCardsNeeded, 3)
        // Truncate back to the raise: drops hero's call, back to hero to act.
        model.truncate(toLedgerIndex: 1)
        XCTAssertEqual(model.ledger.count, 1)
        XCTAssertEqual(model.boardCardsNeeded, 0)
        XCTAssertEqual(model.participantToAct, .hero)
        XCTAssertEqual(model.currentBet, 600)
        // Undo the raise entirely: back to UTG to act at the big blind.
        model.undoLast()
        XCTAssertEqual(model.ledger.count, 0)
        guard let utg = model.villains.first?.id else { return XCTFail("no villain") }
        XCTAssertEqual(model.participantToAct, .villain(utg))
        XCTAssertEqual(model.currentBet, 200)
    }

    /// Removing a villain with recorded actions drops their ledger entries and
    /// the pot/turn state recomputes cleanly.
    func testRemoveVillainDropsLedger() throws {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 20_000)
        model.heroPosition = .btn
        for c in PlayingCard.parseList("Ah Ad") { _ = model.addCard(c) }
        model.addVillain(position: .utg, relative: .coversHero, approxStack: 0)
        model.addVillain(position: .co, relative: .similar, approxStack: 0)
        guard let utg = model.villains.first(where: { $0.position == .utg })?.id,
              let co = model.villains.first(where: { $0.position == .co })?.id else {
            return XCTFail("missing villains")
        }
        model.add(action: .raise, toAmount: 600)           // UTG
        model.add(action: .call, toAmount: 0)              // CO
        XCTAssertEqual(model.ledger.count, 2)
        // Remove UTG: their raise disappears; only CO's action remains.
        model.removeVillain(id: utg)
        XCTAssertFalse(model.ledger.contains { $0.participant == .villain(utg) })
        XCTAssertTrue(model.ledger.contains { $0.participant == .villain(co) })
        XCTAssertNil(model.villains.first(where: { $0.id == utg }))
    }

    /// Removing the ONLY villain mid-hand collapses the replay to hero-only:
    /// the hero's first replayed action ends the hand and books "Hero wins".
    /// This pins the engine behavior behind device finding 10 — it is correct
    /// as replay semantics (a lone participant can't be bet against), which is
    /// exactly why the view must warn before allowing it, even when the
    /// villain being removed never acted (only the hero did).
    func testRemoveLastVillainMidHandEndsHandHeroOnly() throws {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 20_000)
        model.heroPosition = .co
        for c in PlayingCard.parseList("Ah Ad") { _ = model.addCard(c) }
        model.addVillain(position: .bb, relative: .shorter, approxStack: 0)
        guard let bb = model.villains.first?.id else { return XCTFail("no villain") }

        // Hero (CO) opens; the BB villain has NOT acted yet — the view's
        // per-villain hasActed check alone would therefore remove silently.
        XCTAssertEqual(model.participantToAct, .hero)
        model.add(action: .raise, toAmount: 500)
        XCTAssertFalse(model.isHandOver)
        XCTAssertFalse(model.hasActed(.villain(bb)))
        XCTAssertFalse(model.ledger.isEmpty)               // the view's warning trigger

        model.removeVillain(id: bb)

        // Hero-only replay: the raise closes the hand immediately.
        XCTAssertTrue(model.villains.isEmpty)
        XCTAssertTrue(model.isHandOver)
        XCTAssertEqual(model.effectiveWinners, [.hero])
        XCTAssertEqual(model.ledger.count, 1)              // hero's raise survives
    }

    /// Labels format hero and villains per the spec.
    func testLabels() throws {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 20_000)
        model.heroPosition = .btn
        model.addVillain(position: .utg, relative: .coversHero, approxStack: 0)
        model.addVillain(position: .hj, relative: .similar, approxStack: 0)
        model.addVillain(position: .co, relative: .shorter, approxStack: 0)
        guard model.villains.count == 3 else { return XCTFail("expected 3") }
        XCTAssertEqual(model.label(for: .hero), "Hero (BTN)")
        XCTAssertEqual(model.label(for: .villain(model.villains[0].id)), "UTG (covers)")
        XCTAssertEqual(model.label(for: .villain(model.villains[1].id)), "HJ (~same)")
        XCTAssertEqual(model.label(for: .villain(model.villains[2].id)), "CO (short)")
    }

    /// addCard rejects duplicates and respects the hole-card cap.
    func testAddCardCapAndDuplicates() throws {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 20_000)
        XCTAssertTrue(model.addCard(PlayingCard("Ah")!))
        XCTAssertFalse(model.addCard(PlayingCard("Ah")!))    // duplicate
        XCTAssertTrue(model.addCard(PlayingCard("Kd")!))
        XCTAssertFalse(model.addCard(PlayingCard("Qs")!))    // over cap of 2
        XCTAssertEqual(model.heroCards.count, 2)
    }

    /// shouldPushStackUpdate: resolved fresh captures and just-happened
    /// resolved enrichments push; stale enrichments (tracker stack already
    /// moved on) do not, and — since Task 2 — an unresolved hand never
    /// pushes regardless of freshness (there is no real booked result yet).
    func testShouldPushStackUpdate() throws {
        // An unresolved fresh capture never pushes (Task 2: shouldPushStackUpdate
        // additionally requires isResolvable).
        let unresolved = HandCaptureModel(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                                          ante: 25_000, heroCardCount: 2, heroStackBefore: 390_000)
        XCTAssertFalse(unresolved.isResolvable)
        XCTAssertFalse(unresolved.shouldPushStackUpdate)

        // Fresh Log Hand capture (no stub), resolved (no villain — the hero's
        // own action ends the hand with no showdown) → always pushes.
        let fresh = HandCaptureModel(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                                     ante: 25_000, heroCardCount: 2, heroStackBefore: 390_000)
        fresh.heroPosition = .btn
        fresh.add(action: .raise, toAmount: 500)
        XCTAssertTrue(fresh.isResolvable)
        XCTAssertTrue(fresh.shouldPushStackUpdate)

        let stub = HandStub(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000, ante: 25_000,
                            heroStackBefore: 390_000, holeCards: "Kh Kd")

        // Enrichment where the tracker stack still equals the stub's pre-hand
        // snapshot (hand just happened, no update since) → pushes once resolved.
        let current = HandCaptureModel(stub: stub, heroCardCount: 2, trackerStackAtOpen: 390_000)
        current.heroPosition = .btn
        current.add(action: .raise, toAmount: 500)
        XCTAssertTrue(current.shouldPushStackUpdate)

        // Enrichment where later updates moved the tracker on → does not push
        // (re-pushing would regress latestStack — a phantom cliff), even
        // once resolved.
        let stale = HandCaptureModel(stub: stub, heroCardCount: 2, trackerStackAtOpen: 985_000)
        stale.heroPosition = .btn
        stale.add(action: .raise, toAmount: 500)
        XCTAssertTrue(stale.isResolvable)
        XCTAssertFalse(stale.shouldPushStackUpdate)
    }

    // MARK: Board-entry UX fixes (Findings 2 & 3)

    /// `streetBeingDealt` maps board.count → the street actually being dealt
    /// (0/1/2 → flop, 3 → turn, 4 → river), independent of `currentStreet`,
    /// which lags a street behind while cards are owed.
    func testStreetBeingDealtMapsBoardCountToStreet() throws {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 20_000)
        model.heroPosition = .btn
        for c in PlayingCard.parseList("Ah Ad") { _ = model.addCard(c) }
        model.addVillain(position: .co, relative: .similar, approxStack: 0)
        model.add(action: .call, toAmount: 0)          // CO calls the BB
        model.add(action: .call, toAmount: 0)          // hero calls to close

        // Awaiting the flop (board empty): dealt street is flop, even though
        // `currentStreet` is still `.preflop` at this point.
        XCTAssertEqual(model.boardCardsNeeded, 3)
        XCTAssertEqual(model.currentStreet, .preflop)
        XCTAssertEqual(model.streetBeingDealt, .flop)

        XCTAssertTrue(model.addBoardCard(PlayingCard("2c")!))
        XCTAssertEqual(model.streetBeingDealt, .flop)          // 1 of 3 flop cards dealt
        XCTAssertTrue(model.addBoardCard(PlayingCard("7d")!))
        XCTAssertEqual(model.streetBeingDealt, .flop)          // 2 of 3
        XCTAssertTrue(model.addBoardCard(PlayingCard("9s")!))
        XCTAssertEqual(model.currentStreet, .flop)

        // Flop action closes with a check-check → turn is owed. `currentStreet`
        // still reads `.flop` here (the bug: it would mislabel the turn pick as
        // a flop pick), but `streetBeingDealt` correctly reports `.turn`.
        model.add(action: .check, toAmount: 0)
        model.add(action: .check, toAmount: 0)
        XCTAssertEqual(model.boardCardsNeeded, 1)
        XCTAssertEqual(model.currentStreet, .flop)
        XCTAssertEqual(model.streetBeingDealt, .turn)

        XCTAssertTrue(model.addBoardCard(PlayingCard("Ts")!))
        XCTAssertEqual(model.currentStreet, .turn)

        // Turn action closes → river is owed. `currentStreet` still reads
        // `.turn` (the other half of the bug report), `streetBeingDealt` is
        // `.river`.
        model.add(action: .check, toAmount: 0)
        model.add(action: .check, toAmount: 0)
        XCTAssertEqual(model.boardCardsNeeded, 1)
        XCTAssertEqual(model.currentStreet, .turn)
        XCTAssertEqual(model.streetBeingDealt, .river)
    }

    /// `lastInputWasBoardCard` is true only immediately after a board card is
    /// dealt, and flips false the moment any action is recorded afterward —
    /// interleaving board cards and actions must not leave it stuck true.
    func testLastInputWasBoardCardTracksInterleavedInputs() throws {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 20_000)
        model.heroPosition = .btn
        for c in PlayingCard.parseList("Ah Ad") { _ = model.addCard(c) }
        model.addVillain(position: .co, relative: .similar, approxStack: 0)

        XCTAssertFalse(model.lastInputWasBoardCard)            // no inputs yet
        model.add(action: .call, toAmount: 0)
        XCTAssertFalse(model.lastInputWasBoardCard)             // last input is an action
        model.add(action: .call, toAmount: 0)
        XCTAssertFalse(model.lastInputWasBoardCard)

        XCTAssertTrue(model.addBoardCard(PlayingCard("2c")!))
        XCTAssertTrue(model.lastInputWasBoardCard)              // last input is the card just dealt
        XCTAssertTrue(model.addBoardCard(PlayingCard("7d")!))
        XCTAssertTrue(model.lastInputWasBoardCard)
        XCTAssertTrue(model.addBoardCard(PlayingCard("9s")!))
        // The street-closing card drops boardCardsNeeded to 0 synchronously
        // within the same addBoardCard call, yet it must remain removable —
        // this exact state (needed == 0, last input a board card) is the one
        // the board section's inline delete has to be reachable in, so the
        // flag must be TRUE here.
        XCTAssertEqual(model.boardCardsNeeded, 0)
        XCTAssertTrue(model.lastInputWasBoardCard)

        // An action after the flop completes flips it false again.
        model.add(action: .check, toAmount: 0)
        XCTAssertFalse(model.lastInputWasBoardCard)

        // Undoing that action restores the board card as the last input.
        model.undoLast()
        XCTAssertTrue(model.lastInputWasBoardCard)

        // Same invariant on a single-card street: check-check closes the flop,
        // the turn card is owed, and dealing it (needed 1 → 0 in one call)
        // still leaves the just-placed card deletable while the turn betting
        // round opens.
        model.add(action: .check, toAmount: 0)
        model.add(action: .check, toAmount: 0)
        XCTAssertEqual(model.boardCardsNeeded, 1)
        XCTAssertTrue(model.addBoardCard(PlayingCard("Ts")!))
        XCTAssertEqual(model.boardCardsNeeded, 0)
        XCTAssertTrue(model.lastInputWasBoardCard)
        // The inline delete calls undoLast(): the turn card comes back off
        // and is owed again; the last input is now the closing check.
        model.undoLast()
        XCTAssertEqual(model.board.count, 3)
        XCTAssertEqual(model.boardCardsNeeded, 1)
        XCTAssertFalse(model.lastInputWasBoardCard)
    }

    // MARK: setLevel re-seeds blinds (F15)

    /// Changing the level re-seeds the blind postings (dead-blind money and
    /// blind-participant floors) while leaving the recorded ledger amounts —
    /// which are the explicit bet-to totals — untouched.
    func testSetLevelReseedsPotKeepsLedger() throws {
        // Participant blind floors: hero SB + villain BB, no voluntary action.
        // The pot is exactly the two posted blinds, and re-seeds on setLevel.
        let floors = HandCaptureModel(levelNumber: 6, smallBlind: 400, bigBlind: 800,
                                      ante: 0, heroCardCount: 2, heroStackBefore: 40_000)
        floors.heroPosition = .sb
        floors.addVillain(position: .bb, relative: .coversHero, approxStack: 0)
        XCTAssertEqual(floors.pot, 400 + 800)              // SB + BB floors seeded
        XCTAssertTrue(floors.ledger.isEmpty)
        floors.setLevel(number: 5, smallBlind: 300, bigBlind: 600, ante: 0)
        XCTAssertEqual(floors.pot, 300 + 600)              // floors re-seed → pot changes
        XCTAssertTrue(floors.ledger.isEmpty)
        XCTAssertEqual(floors.levelNumber, 5)

        // Dead-blind money + a played-out street: hero BTN vs CO, BB seat empty
        // (dead). Every recorded action is an explicit raise/call-to-raise, so
        // the ledger amounts are blind-independent.
        let model = HandCaptureModel(levelNumber: 6, smallBlind: 400, bigBlind: 800,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 40_000)
        model.heroPosition = .sb
        model.addVillain(position: .co, relative: .coversHero, approxStack: 0)
        guard let co = model.villains.first?.id else { return XCTFail("no villain") }
        // Preflop order: CO then SB. CO raises, hero (SB) calls to close.
        XCTAssertEqual(model.participantToAct, .villain(co))
        model.add(action: .raise, toAmount: 2400)          // CO opens 2400
        model.add(action: .call, toAmount: 0)              // hero (SB) calls
        // Pot: dead BB 800 + CO 2400 + hero 2400 = 5600.
        XCTAssertEqual(model.pot, 5600)
        let ledgerBefore = model.ledger.map(\.toAmount)
        XCTAssertEqual(ledgerBefore, [2400, 2400])

        model.setLevel(number: 5, smallBlind: 300, bigBlind: 600, ante: 0)
        // Dead BB re-seeds 800 → 600; committed raise/call amounts unchanged.
        XCTAssertEqual(model.pot, 5400)
        XCTAssertEqual(model.ledger.map(\.toAmount), ledgerBefore, "ledger amounts unchanged")
    }
}

// MARK: - SizingInput (F13: literal # pad + BB presets)

final class SizingInputTests: XCTestCase {

    private let bb = 25_000

    /// Bare numbers are LITERAL chips — exactly as typed, no additions, no
    /// big-blind heuristics. "3" is 3 chips, not 3 big blinds (the old
    /// ChipInput heuristic multiplied any bare number of <= 3 digits by the
    /// big blind); "2300" is 2,300 chips, with nothing added on top.
    func testBareNumbersAreLiteral() throws {
        XCTAssertEqual(SizingInput.parse("2300", bigBlind: bb), 2300)
        XCTAssertEqual(SizingInput.parse("3", bigBlind: bb), 3)
        XCTAssertEqual(SizingInput.parse(" 75000 ", bigBlind: bb), 75_000)
    }

    /// Explicit "bb" suffix multiplies by the big blind (case-insensitive,
    /// optional space, fractional multiples rounded to the nearest chip).
    func testBBSuffixMultiplies() throws {
        XCTAssertEqual(SizingInput.parse("4bb", bigBlind: bb), 100_000)
        XCTAssertEqual(SizingInput.parse("2.5bb", bigBlind: bb), 62_500)
        XCTAssertEqual(SizingInput.parse("2.5BB", bigBlind: bb), 62_500)
        XCTAssertEqual(SizingInput.parse("4 bb", bigBlind: bb), 100_000)
        // Rounding: 1.5 x 25 = 37.5 -> 38 chips at a 25-chip big blind.
        XCTAssertEqual(SizingInput.parse("1.5bb", bigBlind: 25), 38)
        // No big blind to multiply against -> unresolvable, not garbage-in.
        XCTAssertNil(SizingInput.parse("4bb", bigBlind: 0))
    }

    /// k/m shorthand keeps working.
    func testKMShorthand() throws {
        XCTAssertEqual(SizingInput.parse("42.5k", bigBlind: bb), 42_500)
        XCTAssertEqual(SizingInput.parse("390k", bigBlind: bb), 390_000)
        XCTAssertEqual(SizingInput.parse("1.2m", bigBlind: bb), 1_200_000)
    }

    /// Zero, empty, negative, and unparseable input all resolve to nil (the
    /// confirm button stays disabled).
    func testInvalidInputIsNil() throws {
        XCTAssertNil(SizingInput.parse("0", bigBlind: bb))
        XCTAssertNil(SizingInput.parse("", bigBlind: bb))
        XCTAssertNil(SizingInput.parse("   ", bigBlind: bb))
        XCTAssertNil(SizingInput.parse("garbage", bigBlind: bb))
        XCTAssertNil(SizingInput.parse("-100", bigBlind: bb))
        XCTAssertNil(SizingInput.parse("0bb", bigBlind: bb))
        XCTAssertNil(SizingInput.parse("xbb", bigBlind: bb))
    }

    /// The preflop preset chips ("2bb" / "2.5bb" / "3bb") resolve through this
    /// same parser — the labels ARE the parser inputs in SizingRow — so this
    /// pins the preset math: 2/2.5/3 x BB, and documents the view's disable
    /// rule (a preset is grayed out when its total <= model.currentBet, e.g.
    /// "2bb"/"2.5bb" while facing a raise to 3bb are illegal totals).
    func testPreflopPresetMath() throws {
        XCTAssertEqual(SizingInput.parse("2bb", bigBlind: bb), 50_000)
        XCTAssertEqual(SizingInput.parse("2.5bb", bigBlind: bb), 62_500)
        XCTAssertEqual(SizingInput.parse("3bb", bigBlind: bb), 75_000)
        // Disable rule (view applies `toAmount <= currentBet`): facing a
        // 3bb open (75K), the 2bb and 2.5bb totals are not legal raises.
        let currentBet = 75_000
        XCTAssertLessThanOrEqual(try XCTUnwrap(SizingInput.parse("2bb", bigBlind: bb)), currentBet)
        XCTAssertLessThanOrEqual(try XCTUnwrap(SizingInput.parse("2.5bb", bigBlind: bb)), currentBet)
        XCTAssertGreaterThan(try XCTUnwrap(SizingInput.parse("4bb", bigBlind: bb)), currentBet)
    }
}

// MARK: - HandCaptureModel result flow + save (Task 13)

@MainActor
final class HandCaptureResultTests: XCTestCase {

    // MARK: Brief contract tests

    func testCaptureFullHandKKvs9T() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let t = Tournament(name: "Event 86", buyIn: 500)
        context.insert(t)

        let model = HandCaptureModel(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                                     ante: 25_000, heroCardCount: 2, heroStackBefore: 390_000)
        model.heroPosition = .btn
        for c in PlayingCard.parseList("Kh Kd") { _ = model.addCard(c) }
        model.addVillain(position: .utg, relative: .coversHero, approxStack: 0)
        guard let utg = model.villains.first?.id else { return XCTFail("no villain") }

        model.add(action: .raise, toAmount: 75_000)   // UTG
        model.add(action: .raise, toAmount: 200_000)  // Hero 3-bets
        model.add(action: .allIn, toAmount: 390_000)  // UTG jams (covers)
        model.add(action: .call, toAmount: 0)          // Hero calls all-in

        // All-in preflop → board requested street by street.
        // NOTE: last board card is "3s", not the brief's "Qs": Jh-8h-...-9h-Th
        // would make an 8-9-T-J-Q straight for the villain and beat KK. The
        // evaluator test (testHoldemWinnersKKvs9T) made the same correction.
        for c in PlayingCard.parseList("Jh 8h 4d") { _ = model.addBoardCard(c) }
        _ = model.addBoardCard(PlayingCard("2c")!)
        _ = model.addBoardCard(PlayingCard("3s")!)
        XCTAssertTrue(model.isHandOver)
        XCTAssertTrue(model.needsShowdown)

        model.setShownHolding(PlayingCard.parseList("9h Th"), for: utg)
        XCTAssertEqual(model.computedWinners, [.hero])

        // Pot: ante 25K + dead sb 10K + dead bb 25K + 390K + 390K = 840K
        XCTAssertEqual(model.pot, 840_000)
        // Hero net: 840K − 390K contribution = +450K
        XCTAssertEqual(model.heroNet, 450_000)
        XCTAssertEqual(model.heroStackAfter, 840_000)

        let hand = model.save(into: context, tournament: t, cashSession: nil,
                              sourceStub: nil, tableSize: 9)
        XCTAssertEqual(hand.result, .won)
        XCTAssertEqual(hand.potSize, 840_000)
        XCTAssertEqual(hand.amountWon, 450_000)
        XCTAssertEqual(hand.heroStackAfter, 840_000)
        XCTAssertEqual(hand.sortedVillains.first?.shownHolding, "9h Th")
        XCTAssertEqual(hand.sortedActions.count, 4)
    }

    func testCaptureNoShowdownWinnerIsLastAggressor() throws {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 200, heroCardCount: 2, heroStackBefore: 40_000)
        model.heroPosition = .btn
        for c in PlayingCard.parseList("7h 2c") { _ = model.addCard(c) }
        model.addVillain(position: .bb, relative: .coversHero, approxStack: 0)
        model.add(action: .raise, toAmount: 500)  // hero opens
        model.add(action: .fold, toAmount: 0)     // bb folds
        XCTAssertTrue(model.isHandOver)
        XCTAssertFalse(model.needsShowdown)
        XCTAssertEqual(model.computedWinners, [.hero])
        XCTAssertEqual(model.heroNet, model.pot - 500)
    }

    func testCaptureStubEnrichment() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let t = Tournament(name: "T", buyIn: 100)
        context.insert(t)
        let stub = HandStub(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                            ante: 25_000, heroStackBefore: 390_000, holeCards: "Kh Kd")
        stub.tournament = t
        context.insert(stub)

        let model = HandCaptureModel(stub: stub, heroCardCount: 2)
        XCTAssertEqual(model.heroCards.map(\.raw), ["Kh", "Kd"])   // exact cards prefill
        XCTAssertEqual(model.heroStackBefore, 390_000)

        model.heroPosition = .btn
        model.addVillain(position: .bb, relative: .shorter, approxStack: 0)
        model.add(action: .raise, toAmount: 500_000)  // effectively a jam for test
        model.add(action: .fold, toAmount: 0)
        let hand = model.save(into: context, tournament: t, cashSession: nil,
                              sourceStub: stub, tableSize: 9)
        XCTAssertEqual(stub.status, .enriched)
        XCTAssertIdentical(stub.enrichedHand, hand)
        XCTAssertEqual(stub.heroStackAfter, hand.heroStackAfter)
    }

    // MARK: Suit-agnostic stub leaves hero cards empty

    func testStubSuitAgnosticLeavesCardsEmpty() throws {
        let stub = HandStub(levelNumber: 5, smallBlind: 100, bigBlind: 200, ante: 200,
                            heroStackBefore: 30_000, holeCards: "KQs")
        let model = HandCaptureModel(stub: stub, heroCardCount: 2)
        XCTAssertTrue(model.heroCards.isEmpty)
        XCTAssertEqual(model.heroStackBefore, 30_000)
        XCTAssertEqual(model.levelNumber, 5)
    }

    // MARK: Chop splits remainder to hero

    func testChopSplitsRemainderToHero() throws {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 25, bigBlind: 25,
                                     ante: 1, heroCardCount: 2, heroStackBefore: 10_000)
        model.heroPosition = .btn
        for c in PlayingCard.parseList("2h 3d") { _ = model.addCard(c) }
        model.addVillain(position: .co, relative: .similar, approxStack: 0)
        guard let vid = model.villains.first?.id else { return XCTFail("no villain") }

        // Preflop: CO acts first, raises to 100; hero (BTN) calls.
        model.add(action: .raise, toAmount: 100)   // CO
        model.add(action: .call, toAmount: 0)      // hero
        // Broadway straight lands entirely on the board → both play the board.
        for c in PlayingCard.parseList("As Ks Qd") { _ = model.addBoardCard(c) }
        model.add(action: .check, toAmount: 0)     // CO
        model.add(action: .check, toAmount: 0)     // hero
        _ = model.addBoardCard(PlayingCard("Jc")!)
        model.add(action: .check, toAmount: 0)
        model.add(action: .check, toAmount: 0)
        _ = model.addBoardCard(PlayingCard("Th")!)
        model.add(action: .check, toAmount: 0)
        model.add(action: .check, toAmount: 0)
        XCTAssertTrue(model.isHandOver)
        XCTAssertTrue(model.needsShowdown)

        model.setShownHolding(PlayingCard.parseList("4c 5s"), for: vid)
        XCTAssertEqual(Set(model.computedWinners), Set([.hero, .villain(vid)]))

        // Pot: ante 1 + dead sb 25 + dead bb 25 + 100 + 100 = 251 (odd).
        XCTAssertEqual(model.pot, 251)
        // Chop: base 125 each, remainder 1 to hero → hero share 126; contribution 100.
        XCTAssertEqual(model.heroNet, 26)

        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let hand = model.save(into: context, tournament: nil, cashSession: nil,
                              sourceStub: nil, tableSize: 9)
        XCTAssertEqual(hand.result, .chop)
    }

    // MARK: Mucked villain loses; all-muck → hero wins

    func testMuckedVillainShowdownHeroWins() throws {
        let model = HandCaptureModel(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                                     ante: 25_000, heroCardCount: 2, heroStackBefore: 390_000)
        model.heroPosition = .btn
        for c in PlayingCard.parseList("Kh Kd") { _ = model.addCard(c) }
        model.addVillain(position: .utg, relative: .coversHero, approxStack: 0)
        guard let utg = model.villains.first?.id else { return XCTFail("no villain") }

        model.add(action: .allIn, toAmount: 390_000)  // UTG jams
        model.add(action: .call, toAmount: 0)          // hero calls
        for c in PlayingCard.parseList("Jh 8h 4d") { _ = model.addBoardCard(c) }
        _ = model.addBoardCard(PlayingCard("2c")!)
        _ = model.addBoardCard(PlayingCard("3s")!)
        XCTAssertTrue(model.needsShowdown)

        model.setMucked(utg)          // villain doesn't show → loses by definition
        XCTAssertEqual(model.computedWinners, [.hero])
    }

    // MARK: winnerOverride beats computed winners

    func testWinnerOverrideBeatsComputed() throws {
        let model = HandCaptureModel(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                                     ante: 25_000, heroCardCount: 2, heroStackBefore: 390_000)
        model.heroPosition = .btn
        for c in PlayingCard.parseList("Kh Kd") { _ = model.addCard(c) }
        model.addVillain(position: .utg, relative: .coversHero, approxStack: 0)
        guard let utg = model.villains.first?.id else { return XCTFail("no villain") }

        model.add(action: .allIn, toAmount: 390_000)
        model.add(action: .call, toAmount: 0)
        for c in PlayingCard.parseList("Jh 8h 4d") { _ = model.addBoardCard(c) }
        _ = model.addBoardCard(PlayingCard("2c")!)
        _ = model.addBoardCard(PlayingCard("3s")!)
        model.setShownHolding(PlayingCard.parseList("9h Th"), for: utg)
        XCTAssertEqual(model.computedWinners, [.hero])   // KK wins for real

        // Override the ruling in villain's favour (e.g. a misread corrected by hand).
        model.winnerOverride = [.villain(utg)]
        XCTAssertEqual(model.heroNet, -390_000)          // hero gets nothing, loses stack

        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let hand = model.save(into: context, tournament: nil, cashSession: nil,
                              sourceStub: nil, tableSize: 9)
        XCTAssertEqual(hand.result, .lost)
        XCTAssertFalse(hand.winnerOverride.isEmpty)
    }

    /// F14: a winnerOverride describes one specific final hand state — any
    /// input that changes the replay (actions, board cards, undo, truncate,
    /// villain removal) or the showdown evidence (shown holdings, mucks, hero
    /// cards) auto-clears it. A stale override that survives such edits
    /// silently flips provably-won hands ("Hero loses" on a hand KK wins).
    func testWinnerOverrideAutoClearsOnHandMutation() throws {
        // Replay mutations: each of action / board card / undo clears it.
        let model = HandCaptureModel(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                                     ante: 25_000, heroCardCount: 2, heroStackBefore: 390_000)
        model.heroPosition = .btn
        for c in PlayingCard.parseList("Kh Kd") { _ = model.addCard(c) }
        model.addVillain(position: .utg, relative: .coversHero, approxStack: 0)
        let utg = try XCTUnwrap(model.villains.first?.id)

        model.winnerOverride = [.hero]
        model.add(action: .allIn, toAmount: 390_000)          // UTG jams
        XCTAssertNil(model.winnerOverride, "an action must clear the override")

        model.winnerOverride = [.hero]
        model.add(action: .call, toAmount: 0)                 // hero calls
        XCTAssertNil(model.winnerOverride)

        model.winnerOverride = [.hero]
        for c in PlayingCard.parseList("Jh 8h 4d 2c 3s") { _ = model.addBoardCard(c) }
        XCTAssertNil(model.winnerOverride, "board cards must clear the override")

        // Showdown-evidence mutations (bypass rebuild): shown holding / muck.
        model.winnerOverride = [.villain(utg)]
        model.setShownHolding(PlayingCard.parseList("9h Th"), for: utg)
        XCTAssertNil(model.winnerOverride, "shown cards must clear the override")

        model.winnerOverride = [.villain(utg)]
        model.setMucked(utg)
        XCTAssertNil(model.winnerOverride, "a muck must clear the override")

        // Undo is a replay mutation too.
        model.winnerOverride = [.villain(utg)]
        model.undoLast()
        XCTAssertNil(model.winnerOverride, "undo must clear the override")
    }

    /// F14: pure reads never touch an active override — it survives every
    /// derived-state access and still decides the result until the next
    /// mutation.
    func testWinnerOverrideSurvivesPureReads() throws {
        let (model, utg) = makeShowdownModel()
        model.setShownHolding(PlayingCard.parseList("9h Th"), for: utg)
        XCTAssertEqual(model.computedWinners, [.hero])        // KK wins for real

        model.winnerOverride = [.villain(utg)]
        // Exercise the derived reads the Result block and Save button use.
        _ = model.heroNet
        _ = model.pot
        _ = model.effectiveWinners
        _ = model.computedWinners
        _ = model.isResolvable
        _ = model.needsShowdown
        _ = model.narration
        _ = model.legalActions
        _ = model.dealtCards
        XCTAssertEqual(model.winnerOverride, [.villain(utg)],
                       "pure reads must not clear the override")
        XCTAssertEqual(model.heroNet, -390_000, "the override still decides the result")
    }

    // MARK: - isResolvable / Save gating (Task 14)

    /// Builds an all-in-preflop heads-up hand (hero BTN vs UTG) run out to the
    /// river — a real showdown. `withHeroCards: false` leaves the hero's cards
    /// unentered, making the showdown unevaluable.
    private func makeShowdownModel(withHeroCards: Bool = true) -> (HandCaptureModel, UUID) {
        let model = HandCaptureModel(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                                     ante: 25_000, heroCardCount: 2, heroStackBefore: 390_000)
        model.heroPosition = .btn
        if withHeroCards {
            for c in PlayingCard.parseList("Kh Kd") { _ = model.addCard(c) }
        }
        model.addVillain(position: .utg, relative: .coversHero, approxStack: 0)
        let utg = model.villains.first!.id
        model.add(action: .allIn, toAmount: 390_000)  // UTG jams
        model.add(action: .call, toAmount: 0)          // hero calls
        for c in PlayingCard.parseList("Jh 8h 4d 2c 3s") { _ = model.addBoardCard(c) }
        return (model, utg)
    }

    func testIsResolvableGating() throws {
        // Mid-hand: not resolvable.
        let midHand = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                       ante: 0, heroCardCount: 2, heroStackBefore: 20_000)
        midHand.heroPosition = .btn
        midHand.addVillain(position: .utg, relative: .similar, approxStack: 0)
        midHand.add(action: .raise, toAmount: 500)
        XCTAssertFalse(midHand.isResolvable)

        // Fold-out (no showdown): resolvable with no further input.
        midHand.add(action: .fold, toAmount: 0)
        XCTAssertTrue(midHand.isHandOver)
        XCTAssertFalse(midHand.needsShowdown)
        XCTAssertTrue(midHand.isResolvable)

        // Showdown with an unresolved villain: blocked.
        let (model, utg) = makeShowdownModel()
        XCTAssertTrue(model.needsShowdown)
        XCTAssertFalse(model.isResolvable, "unresolved villain must block Save")

        // Explicit muck resolves it (hero wins by default).
        model.setMucked(utg)
        XCTAssertTrue(model.isResolvable)

        // A shown two-card holding also resolves it.
        model.setShownHolding(PlayingCard.parseList("9h Th"), for: utg)
        XCTAssertTrue(model.isResolvable)
        XCTAssertEqual(model.computedWinners, [.hero])
    }

    func testIsResolvableBlocksUnevaluableShowdown() throws {
        // Hero cards never entered: villains resolve but the showdown cannot
        // be evaluated — Save must stay blocked rather than booking an
        // automatic hero loss.
        let (model, utg) = makeShowdownModel(withHeroCards: false)
        model.setShownHolding(PlayingCard.parseList("9h Th"), for: utg)
        XCTAssertTrue(model.needsShowdown)
        XCTAssertTrue(model.computedWinners.isEmpty)
        XCTAssertFalse(model.isResolvable, "unevaluable showdown must block Save")

        // A manual override settles it.
        model.winnerOverride = [.villain(utg)]
        XCTAssertTrue(model.isResolvable)
    }

    // MARK: - Verbatim dictation transcript (Task 2)

    /// `canSave` opens up a second path beyond `isResolvable`: a transcript
    /// alone — with a completely untouched (empty) ledger — makes the hand
    /// savable, even though it can never be `isResolvable` (that requires
    /// `isHandOver`).
    func testCanSaveWithTranscriptOnly() throws {
        let model = HandCaptureModel(levelNumber: 5, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 20_000)
        XCTAssertFalse(model.isHandOver)
        XCTAssertFalse(model.isResolvable)
        XCTAssertFalse(model.canSave, "no transcript, no resolved ledger — nothing to save")

        model.transcript = "Raised UTG, three-bet, folded to a jam."
        XCTAssertFalse(model.isResolvable, "an empty ledger is never resolvable")
        XCTAssertTrue(model.canSave, "a transcript alone must open the Save gate")
    }

    /// A transcript-only save (empty ledger) persists the transcript
    /// verbatim to `hand.notes` and never pushes a tracker stack update —
    /// there is no real booked result to trust (`shouldPushStackUpdate` now
    /// additionally requires `isResolvable`).
    @MainActor
    func testTranscriptOnlySavePersistsNotesAndSkipsStackPush() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let t = Tournament(name: "Event 1", buyIn: 100)
        context.insert(t)

        let model = HandCaptureModel(levelNumber: 5, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 20_000)
        model.transcript = "Limped UTG with 7-2, saw a cheap flop, folded to a bet on the turn."
        XCTAssertFalse(model.isResolvable)
        XCTAssertTrue(model.canSave)
        XCTAssertFalse(model.shouldPushStackUpdate, "transcript-only saves never push")

        let hand = model.save(into: context, tournament: t, cashSession: nil,
                              sourceStub: nil, tableSize: 9)
        XCTAssertEqual(hand.notes, model.transcript)
        XCTAssertTrue(hand.sortedActions.isEmpty)
        XCTAssertFalse(model.shouldPushStackUpdate)
    }

    func testHasActed() throws {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 20_000)
        model.heroPosition = .btn
        model.addVillain(position: .utg, relative: .similar, approxStack: 0)
        let utg = model.villains.first!.id
        XCTAssertFalse(model.hasActed(.villain(utg)))
        model.add(action: .raise, toAmount: 500)      // UTG acts first
        XCTAssertTrue(model.hasActed(.villain(utg)))
        XCTAssertFalse(model.hasActed(.hero))
    }

    // MARK: - narration (Task 14)

    func testNarrationRendersHandSoFar() throws {
        let model = HandCaptureModel(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                                     ante: 25_000, heroCardCount: 2, heroStackBefore: 390_000)
        model.heroPosition = .btn
        for c in PlayingCard.parseList("Ks Qs") { XCTAssertTrue(model.addCard(c)) }
        model.addVillain(position: .utg, relative: .coversHero, approxStack: 0)

        model.add(action: .raise, toAmount: 75_000)    // UTG opens
        model.add(action: .raise, toAmount: 200_000)   // Hero 3-bets

        let narration = model.narration
        XCTAssertTrue(narration.contains("Hero BTN"), narration)
        XCTAssertTrue(narration.contains("K♠"), narration)
        XCTAssertTrue(narration.contains("Q♠"), narration)
        XCTAssertTrue(narration.contains("UTG"), narration)
        XCTAssertTrue(narration.contains("raises to 75,000"), narration)
        XCTAssertTrue(narration.contains("raises to 200,000"), narration)
        XCTAssertFalse(narration.contains("Pot"), narration)

        model.add(action: .call, toAmount: 0)          // UTG calls, closing preflop

        // Board cards fold into the street segment once dealt.
        for c in PlayingCard.parseList("Jh 8h 4d") { XCTAssertTrue(model.addBoardCard(c)) }
        let flopNarration = model.narration
        XCTAssertTrue(flopNarration.contains("FLOP"), flopNarration)
        XCTAssertTrue(flopNarration.contains("J♥"), flopNarration)
    }

    // MARK: - init(editing:) round-trip (F16)

    /// The KK-vs-9T reference hand, built through the normal capture API,
    /// saved, then reconstructed via `init(editing:)`, reproduces the exact
    /// ledger amounts / participant shape, board, pot, hand-over flag, and
    /// computed winners. Engine determinism makes this an equality check.
    func testEditRoundTripReconstructsIdentically() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let model = HandCaptureModel(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                                     ante: 25_000, heroCardCount: 2, heroStackBefore: 390_000)
        model.heroPosition = .btn
        for c in PlayingCard.parseList("Kh Kd") { _ = model.addCard(c) }
        model.addVillain(position: .utg, relative: .coversHero, approxStack: 0)
        let utg = try XCTUnwrap(model.villains.first?.id)
        model.add(action: .raise, toAmount: 75_000)    // UTG
        model.add(action: .raise, toAmount: 200_000)   // Hero 3-bets
        model.add(action: .allIn, toAmount: 390_000)   // UTG jams
        model.add(action: .call, toAmount: 0)           // Hero calls
        for c in PlayingCard.parseList("Jh 8h 4d") { _ = model.addBoardCard(c) }
        _ = model.addBoardCard(PlayingCard("2c")!)
        _ = model.addBoardCard(PlayingCard("3s")!)
        model.setShownHolding(PlayingCard.parseList("9h Th"), for: utg)
        model.selectedTags = ["Cooler"]

        let original = model.save(into: context, tournament: nil, cashSession: nil,
                                  sourceStub: nil, tableSize: 9)

        // Reconstruct from the persisted hand.
        let rebuilt = HandCaptureModel(editing: original, heroCardCount: 2)

        XCTAssertEqual(rebuilt.ledger.map(\.toAmount), model.ledger.map(\.toAmount))
        XCTAssertEqual(rebuilt.ledger.map { $0.participant == .hero },
                       model.ledger.map { $0.participant == .hero })
        XCTAssertEqual(rebuilt.ledger.map(\.action), model.ledger.map(\.action))
        XCTAssertEqual(rebuilt.board, model.board)
        XCTAssertEqual(rebuilt.pot, model.pot)
        XCTAssertEqual(rebuilt.isHandOver, model.isHandOver)
        XCTAssertEqual(rebuilt.heroNet, model.heroNet)
        XCTAssertEqual(Set(rebuilt.computedWinners), Set(model.computedWinners))
        XCTAssertEqual(rebuilt.computedWinners, [.hero])
        XCTAssertEqual(rebuilt.heroCards, model.heroCards)
        XCTAssertEqual(rebuilt.selectedTags, ["Cooler"])
    }

    /// A dictation transcript survives an edit round-trip: `save()` writes it
    /// to `hand.notes`, and `init(editing:)` restores it back onto
    /// `transcript` (Task 2).
    @MainActor
    func testEditRoundTripCarriesTranscript() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let model = HandCaptureModel(levelNumber: 5, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 20_000)
        model.transcript = "Opened UTG, got three-bet, folded — thought I was way behind."

        let original = model.save(into: context, tournament: nil, cashSession: nil,
                                  sourceStub: nil, tableSize: 9)
        XCTAssertEqual(original.notes, model.transcript)

        let rebuilt = HandCaptureModel(editing: original, heroCardCount: 2)
        XCTAssertEqual(rebuilt.transcript, model.transcript)
    }

    // MARK: - potOverride hygiene (F17)

    /// A manual pot override auto-clears on every hand mutation, exactly like
    /// winnerOverride (F14): replay mutations via rebuild(), and the showdown /
    /// hero-card paths that bypass rebuild clear it explicitly.
    func testPotOverrideAutoClearsOnHandMutation() throws {
        let model = HandCaptureModel(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                                     ante: 25_000, heroCardCount: 2, heroStackBefore: 390_000)
        model.heroPosition = .btn
        model.addVillain(position: .utg, relative: .coversHero, approxStack: 0)
        let utg = try XCTUnwrap(model.villains.first?.id)

        // addCard clears it explicitly.
        model.potOverride = 999_999
        XCTAssertTrue(model.addCard(PlayingCard("Kh")!))
        XCTAssertNil(model.potOverride, "adding a hero card must clear the pot override")
        _ = model.addCard(PlayingCard("Kd")!)

        // Actions (via rebuild) clear it.
        model.potOverride = 999_999
        model.add(action: .allIn, toAmount: 390_000)          // UTG jams
        XCTAssertNil(model.potOverride, "an action must clear the pot override")

        model.potOverride = 999_999
        model.add(action: .call, toAmount: 0)                 // hero calls
        XCTAssertNil(model.potOverride)

        // Board cards (via rebuild) clear it.
        model.potOverride = 999_999
        for c in PlayingCard.parseList("Jh 8h 4d 2c 3s") { _ = model.addBoardCard(c) }
        XCTAssertNil(model.potOverride, "board cards must clear the pot override")

        // Showdown evidence (bypasses rebuild) clears it explicitly.
        model.potOverride = 999_999
        model.setShownHolding(PlayingCard.parseList("9h Th"), for: utg)
        XCTAssertNil(model.potOverride, "shown cards must clear the pot override")

        model.potOverride = 999_999
        model.setMucked(utg)
        XCTAssertNil(model.potOverride, "a muck must clear the pot override")

        // Undo is a replay mutation too.
        model.potOverride = 999_999
        model.undoLast()
        XCTAssertNil(model.potOverride, "undo must clear the pot override")
    }

    /// Pure reads never touch an active pot override — it survives derived
    /// reads (including `pot`, which returns it) until the next mutation.
    func testPotOverrideSurvivesPureReads() throws {
        let model = HandCaptureModel(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                                     ante: 25_000, heroCardCount: 2, heroStackBefore: 390_000)
        model.heroPosition = .btn
        model.addVillain(position: .utg, relative: .coversHero, approxStack: 0)
        model.potOverride = 1_234_000
        _ = model.pot
        _ = model.heroNet
        _ = model.narration
        _ = model.legalActions
        XCTAssertEqual(model.potOverride, 1_234_000, "pure reads must not clear the override")
        XCTAssertEqual(model.pot, 1_234_000, "the override still decides the pot")
    }

    // MARK: - Save-time result/net consistency guard (F17)

    /// The sign guard flips an impossible result/net pairing (a sole win that
    /// nets negative, a loss that nets positive) and leaves the legitimate
    /// cases — including a net-negative chop from unequal contributions — alone.
    func testConsistentResultClampsSignMismatch() {
        XCTAssertEqual(HandCaptureModel.consistentResult(.won, net: -100), .lost)
        XCTAssertEqual(HandCaptureModel.consistentResult(.lost, net: 100), .won)
        XCTAssertEqual(HandCaptureModel.consistentResult(.won, net: 100), .won)
        XCTAssertEqual(HandCaptureModel.consistentResult(.lost, net: -100), .lost)
        XCTAssertEqual(HandCaptureModel.consistentResult(.won, net: 0), .won)
        // A chop can legitimately net negative when the hero contributed more
        // than an even split (a villain short all-in) — never treated as
        // corruption.
        XCTAssertEqual(HandCaptureModel.consistentResult(.chop, net: -100), .chop)
        XCTAssertEqual(HandCaptureModel.consistentResult(.folded, net: -50), .folded)
    }

    // MARK: - winnerOverride restore on edit (F16 follow-up)

    /// An NLHE dealer-correction override survives an edit round-trip: the
    /// persisted label string ("UTG (covers)") matches the reconstructed
    /// villain's identical label, restoring the exact participant — without
    /// this the override silently reverts to the computed winner on save.
    func testEditRestoresWinnerOverrideByLabel() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let model = HandCaptureModel(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                                     ante: 25_000, heroCardCount: 2, heroStackBefore: 390_000)
        model.heroPosition = .btn
        for c in PlayingCard.parseList("Kh Kd") { _ = model.addCard(c) }
        model.addVillain(position: .utg, relative: .coversHero, approxStack: 0)
        let utg = try XCTUnwrap(model.villains.first?.id)
        model.add(action: .allIn, toAmount: 390_000)
        model.add(action: .call, toAmount: 0)
        for c in PlayingCard.parseList("Jh 8h 4d 2c 3s") { _ = model.addBoardCard(c) }
        model.setShownHolding(PlayingCard.parseList("9h Th"), for: utg)
        XCTAssertEqual(model.computedWinners, [.hero])   // KK wins for real

        model.winnerOverride = [.villain(utg)]           // dealer correction
        let saved = model.save(into: context, tournament: nil, cashSession: nil,
                               sourceStub: nil, tableSize: 9)
        XCTAssertEqual(saved.winnerOverride, "UTG (covers)")

        let rebuilt = HandCaptureModel(editing: saved, heroCardCount: 2)
        XCTAssertNil(rebuilt.winnerOverride, "reconstruction alone must not invent an override")
        rebuilt.restoreWinnerOverride(fromLabels: saved.winnerOverride)
        let newUtg = try XCTUnwrap(rebuilt.villains.first?.id)
        XCTAssertEqual(rebuilt.winnerOverride, [.villain(newUtg)])
        XCTAssertTrue(rebuilt.isResolvable)
        XCTAssertEqual(rebuilt.heroNet, -390_000, "the restored override decides the result")
    }

    /// PLO showdowns are only saveable via an override (`computedWinners` is
    /// hold'em-only). Editing one must restore the override, or the reopened
    /// hand comes back with Save permanently disabled.
    func testEditRestoresOverrideForPLOShowdown() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let model = HandCaptureModel(levelNumber: 5, smallBlind: 300, bigBlind: 600,
                                     ante: 600, heroCardCount: 4, heroStackBefore: 50_000)
        model.heroPosition = .btn
        for c in PlayingCard.parseList("Ah Kh Qd Jd") { _ = model.addCard(c) }
        model.addVillain(position: .utg, relative: .coversHero, approxStack: 0)
        model.add(action: .allIn, toAmount: 50_000)   // UTG jams
        model.add(action: .call, toAmount: 0)          // hero calls
        for c in PlayingCard.parseList("Th 9h 4c 2s 7d") { _ = model.addBoardCard(c) }
        XCTAssertTrue(model.needsShowdown)
        XCTAssertTrue(model.computedWinners.isEmpty, "PLO showdowns are unevaluable")
        XCTAssertFalse(model.isResolvable, "PLO showdown needs an override to save")

        model.winnerOverride = [.hero]
        XCTAssertTrue(model.isResolvable)
        let saved = model.save(into: context, tournament: nil, cashSession: nil,
                               sourceStub: nil, tableSize: 9)

        let rebuilt = HandCaptureModel(editing: saved, heroCardCount: 4)
        XCTAssertFalse(rebuilt.isResolvable, "without restore, Save would be disabled")
        rebuilt.restoreWinnerOverride(fromLabels: saved.winnerOverride)
        XCTAssertEqual(rebuilt.winnerOverride, [.hero])
        XCTAssertTrue(rebuilt.isResolvable, "restored override re-enables Save")
    }

    /// A stored override string that matches no participant restores nothing:
    /// all-or-nothing matching, no partial sets, no crash.
    func testRestoreWinnerOverrideIgnoresUnmatchableLabels() throws {
        let (model, utg) = makeShowdownModel()
        model.setShownHolding(PlayingCard.parseList("9h Th"), for: utg)

        model.restoreWinnerOverride(fromLabels: "HJ (short)")   // no such participant
        XCTAssertNil(model.winnerOverride)

        // One matching + one garbage token → all-or-nothing, still nothing.
        model.restoreWinnerOverride(fromLabels: "Hero (BTN), Garbage Token")
        XCTAssertNil(model.winnerOverride)

        model.restoreWinnerOverride(fromLabels: "")             // empty = no override saved
        XCTAssertNil(model.winnerOverride)

        // Sanity: a fully-matching string does restore.
        model.restoreWinnerOverride(fromLabels: "Hero (BTN)")
        XCTAssertEqual(model.winnerOverride, [.hero])
    }

    /// Edit round-trip with betting on every street — board cards interleaved
    /// with live action (flop cards then flop bets, etc.), not just an all-in
    /// runout. The reconstructed ledger must be identical entry-for-entry.
    func testEditRoundTripWithPostflopBetting() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let model = HandCaptureModel(levelNumber: 6, smallBlind: 400, bigBlind: 800,
                                     ante: 800, heroCardCount: 2, heroStackBefore: 60_000)
        model.heroPosition = .btn
        for c in PlayingCard.parseList("Kh Kd") { _ = model.addCard(c) }
        model.addVillain(position: .bb, relative: .coversHero, approxStack: 0)
        let bb = try XCTUnwrap(model.villains.first?.id)

        model.add(action: .raise, toAmount: 2000)      // hero (BTN) opens
        model.add(action: .call, toAmount: 0)          // BB defends
        for c in PlayingCard.parseList("Jh 8c 4d") { _ = model.addBoardCard(c) }
        model.add(action: .check, toAmount: 0)         // BB
        model.add(action: .bet, toAmount: 2500)        // hero
        model.add(action: .call, toAmount: 0)          // BB
        _ = model.addBoardCard(PlayingCard("2c")!)
        model.add(action: .check, toAmount: 0)         // BB
        model.add(action: .check, toAmount: 0)         // hero
        _ = model.addBoardCard(PlayingCard("3s")!)
        model.add(action: .bet, toAmount: 5000)        // BB leads river
        model.add(action: .call, toAmount: 0)          // hero calls
        XCTAssertTrue(model.isHandOver)
        model.setShownHolding(PlayingCard.parseList("9h Th"), for: bb)
        XCTAssertEqual(model.computedWinners, [.hero])

        let saved = model.save(into: context, tournament: nil, cashSession: nil,
                               sourceStub: nil, tableSize: 9)
        let rebuilt = HandCaptureModel(editing: saved, heroCardCount: 2)

        XCTAssertEqual(rebuilt.ledger.map(\.toAmount), model.ledger.map(\.toAmount))
        XCTAssertEqual(rebuilt.ledger.map(\.action), model.ledger.map(\.action))
        XCTAssertEqual(rebuilt.ledger.map(\.street), model.ledger.map(\.street))
        XCTAssertEqual(rebuilt.ledger.map { $0.participant == .hero },
                       model.ledger.map { $0.participant == .hero })
        XCTAssertEqual(rebuilt.board, model.board)
        XCTAssertEqual(rebuilt.pot, model.pot)
        XCTAssertEqual(rebuilt.isHandOver, model.isHandOver)
        XCTAssertEqual(Set(rebuilt.computedWinners), Set(model.computedWinners))
        XCTAssertEqual(rebuilt.heroNet, model.heroNet)
    }
}

// MARK: - DictationEngine

final class DictationEngineTests: XCTestCase {

    @MainActor
    func testDictationEngineInitialStateAndTranscriptComposition() {
        let engine = DictationEngine()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(engine.fullTranscript, "")
    }
}

// MARK: - Hand History Formatter

final class HandHistoryFormatterTests: XCTestCase {

    private func referenceHand() -> Hand {
        let hand = Hand(heroPosition: .btn, heroCardsRaw: "Ks Kd",
                        levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                        ante: 25_000, heroStackChips: 390_000)
        hand.boardRaw = "Jh 8h 4d 2c 3s"
        hand.resultRaw = HandResult.won.rawValue
        hand.potSize = 840_000
        hand.amountWon = 450_000
        let actions: [(HeroPosition, HandActionType, Int, Bool)] = [
            (.utg, .raise, 75_000, false),
            (.btn, .raise, 200_000, true),
            (.utg, .allIn, 390_000, false),
            (.btn, .call, 0, true),
        ]
        for (i, a) in actions.enumerated() {
            let act = HandAction(orderIndex: i, street: .preflop, position: a.0,
                                 actionType: a.1, amount: a.2, isHero: a.3)
            act.hand = hand
            hand.actions?.append(act)
        }
        let villain = HandVillain(orderIndex: 0, position: .utg, relativeStack: .coversHero)
        villain.shownHolding = "9h Th"
        villain.hand = hand
        hand.villains?.append(villain)
        return hand
    }

    func testFormatsReferenceHand() {
        let expected = """
        Level 21 — 10,000/25,000 (25,000) · Hero BTN K♠K♦ (390,000)
        PRE: UTG raises to 75,000 · Hero raises to 200,000 · UTG all-in 390,000 · Hero calls
        FLOP J♥8♥4♦
        TURN 2♣
        RIVER 3♠
        UTG shows 9♥T♥ — Hero wins 840,000 (+450,000)
        """
        XCTAssertEqual(HandHistoryFormatter.text(for: referenceHand()), expected)
    }

    func testFormatsPreflopFoldWithoutBoard() {
        let hand = Hand(heroPosition: .co, heroCardsRaw: "Ah Jc",
                        levelNumber: 3, smallBlind: 200, bigBlind: 400,
                        ante: 400, heroStackChips: 55_000)
        hand.resultRaw = HandResult.folded.rawValue
        let acts: [(HeroPosition, HandActionType, Int, Bool)] = [
            (.co, .raise, 1_000, true), (.bb, .raise, 3_500, false), (.co, .fold, 0, true),
        ]
        for (i, a) in acts.enumerated() {
            let act = HandAction(orderIndex: i, street: .preflop, position: a.0,
                                 actionType: a.1, amount: a.2, isHero: a.3)
            act.hand = hand
            hand.actions?.append(act)
        }
        let expected = """
        Level 3 — 200/400 (400) · Hero CO A♥J♣ (55,000)
        PRE: Hero raises to 1,000 · BB raises to 3,500 · Hero folds
        Hero folds
        """
        XCTAssertEqual(HandHistoryFormatter.text(for: hand), expected)
    }

    func testFormatsCashHeaderAndPostflopActions() {
        let hand = Hand(heroPosition: .btn, heroCardsRaw: "Qs Qd", stakes: "$1/$3")
        hand.boardRaw = "Jh 8h 4d"
        hand.resultRaw = HandResult.won.rawValue
        hand.amountWon = 120
        let acts: [(HandStreet, HeroPosition, HandActionType, Int, Bool)] = [
            (.preflop, .btn, .raise, 15, true), (.preflop, .bb, .call, 0, false),
            (.flop, .bb, .check, 0, false), (.flop, .btn, .bet, 20, true),
            (.flop, .bb, .fold, 0, false),
        ]
        for (i, a) in acts.enumerated() {
            let act = HandAction(orderIndex: i, street: a.0, position: a.1,
                                 actionType: a.2, amount: a.3, isHero: a.4)
            act.hand = hand
            hand.actions?.append(act)
        }
        let expected = """
        $1/$3 · Hero BTN Q♠Q♦
        PRE: Hero raises to 15 · BB calls
        FLOP J♥8♥4♦: BB checks · Hero bets 20 · BB folds
        Hero wins (+120)
        """
        XCTAssertEqual(HandHistoryFormatter.text(for: hand), expected)
    }

    func testFormatsChopAndMuckedVillainExcluded() {
        let hand = Hand(heroPosition: .sb, heroCardsRaw: "Ah Kh",
                        levelNumber: 0, smallBlind: 100, bigBlind: 200,
                        ante: 0, heroStackChips: 0)
        hand.resultRaw = HandResult.chop.rawValue
        hand.potSize = 3_000
        hand.amountWon = 0
        let shown = HandVillain(orderIndex: 0, position: .bb, relativeStack: .similar)
        shown.shownHolding = "Ad Kd"
        shown.hand = hand
        hand.villains?.append(shown)
        let mucked = HandVillain(orderIndex: 1, position: .co, relativeStack: .shorter)
        mucked.hand = hand
        hand.villains?.append(mucked)
        let expected = """
        100/200 · Hero SB A♥K♥
        BB shows A♦K♦ — Chop
        """
        XCTAssertEqual(HandHistoryFormatter.text(for: hand), expected)
    }

    func testPartialHandNeverCrashes() {
        let hand = Hand()
        let text = HandHistoryFormatter.text(for: hand)
        XCTAssertFalse(text.isEmpty)   // at least the result line ("Hero folds" default)
    }

    /// A chop that leaves the hero net-negative (short-stack tie: the flat
    /// split returns less than hero put in) must render "(-350)", never "(+-350)".
    func testNetNegativeChopRendersProperSign() {
        let hand = Hand(heroPosition: .sb, heroCardsRaw: "Ah Kh",
                        levelNumber: 0, smallBlind: 100, bigBlind: 200,
                        ante: 0, heroStackChips: 0)
        hand.resultRaw = HandResult.chop.rawValue
        hand.amountWon = -350
        let text = HandHistoryFormatter.text(for: hand)
        XCTAssertTrue(text.hasSuffix("Chop (-350)"), "got: \(text)")
        XCTAssertFalse(text.contains("+-"), "malformed sign: \(text)")
    }

    /// A won hand with amountWon == 0 keeps omitting the parenthetical.
    func testWonWithZeroAmountOmitsParenthetical() {
        let hand = Hand(heroPosition: .sb, heroCardsRaw: "Ah Kh",
                        levelNumber: 0, smallBlind: 100, bigBlind: 200,
                        ante: 0, heroStackChips: 0)
        hand.resultRaw = HandResult.won.rawValue
        hand.potSize = 3_000
        hand.amountWon = 0
        let text = HandHistoryFormatter.text(for: hand)
        XCTAssertTrue(text.hasSuffix("Hero wins 3,000"), "got: \(text)")
    }

    // MARK: - Verbatim dictation transcript (Task 2)

    /// A dictated-only hand (no recorded ledger) never booked a real result —
    /// the result line is omitted entirely, and the transcript is appended
    /// as the final block.
    func testFormatterDictatedOnlyHandOmitsResultAndAppendsTranscript() {
        let hand = Hand(heroPosition: .btn, heroCardsRaw: "Ah Kd",
                        levelNumber: 5, smallBlind: 100, bigBlind: 200,
                        ante: 0, heroStackChips: 20_000)
        hand.notes = "Raised UTG, got three-bet, folded — think I was way behind."
        let text = HandHistoryFormatter.text(for: hand)
        XCTAssertFalse(text.contains("Hero folds"), "got: \(text)")
        XCTAssertTrue(text.contains("— Transcript —"), "got: \(text)")
        XCTAssertTrue(text.contains(hand.notes), "got: \(text)")
    }

    /// A structured hand that ALSO carries a dictated note keeps its normal
    /// result line, with the transcript block appended after it.
    func testFormatterStructuredHandWithNotesAppendsTranscriptAfterResult() {
        let hand = Hand(heroPosition: .co, heroCardsRaw: "Ah Jc",
                        levelNumber: 3, smallBlind: 200, bigBlind: 400,
                        ante: 400, heroStackChips: 55_000)
        hand.resultRaw = HandResult.folded.rawValue
        let acts: [(HeroPosition, HandActionType, Int, Bool)] = [
            (.co, .raise, 1_000, true), (.bb, .raise, 3_500, false), (.co, .fold, 0, true),
        ]
        for (i, a) in acts.enumerated() {
            let act = HandAction(orderIndex: i, street: .preflop, position: a.0,
                                 actionType: a.1, amount: a.2, isHero: a.3)
            act.hand = hand
            hand.actions?.append(act)
        }
        hand.notes = "Villain had been three-betting light all night, should have called."
        let text = HandHistoryFormatter.text(for: hand)
        XCTAssertTrue(text.contains("Hero folds"), "got: \(text)")
        guard let resultRange = text.range(of: "Hero folds"),
              let transcriptRange = text.range(of: "— Transcript —") else {
            return XCTFail("missing expected sections: \(text)")
        }
        XCTAssertTrue(resultRange.upperBound <= transcriptRange.lowerBound,
                      "transcript block must follow the result line: \(text)")
        XCTAssertTrue(text.contains(hand.notes), "got: \(text)")
    }

    // MARK: - Unknown suit (x) rendering

    func testFormatterRendersUnknownSuitCards() {
        let hand = Hand(heroPosition: .co, heroCardsRaw: "Ac Kx",
                        levelNumber: 3, smallBlind: 200, bigBlind: 400,
                        ante: 400, heroStackChips: 55_000)
        hand.resultRaw = HandResult.folded.rawValue
        let text = HandHistoryFormatter.text(for: hand)
        XCTAssertTrue(text.contains("A♣Kx"))
    }
}

// Regression: user-reported device hand (straight vs trips) — engine verified correct;
// pins evaluator + full-flow winner computation for this exact sequence.
final class StraightVsTripsDiagTests: XCTestCase {
    func testEvaluatorStraightBeatsTrips() throws {
        let hero = UUID(), villain = UUID()
        let winners = PokerHandEvaluator.holdemWinners(
            board: PlayingCard.parseList("4h 3c Ad 5h 7h"),
            holdings: [(hero, PlayingCard.parseList("6h 5d")),
                       (villain, PlayingCard.parseList("Ah As"))])
        XCTAssertEqual(winners, [hero], "6h5d makes 3-7 straight, must beat trip aces")
    }

    @MainActor
    func testFullCaptureFlowStraightVsTrips() throws {
        let model = HandCaptureModel(levelNumber: 6, smallBlind: 400, bigBlind: 800,
                                     ante: 800, heroCardCount: 2, heroStackBefore: 425_000)
        model.heroPosition = .sb
        for c in PlayingCard.parseList("6h 5d") { XCTAssertTrue(model.addCard(c)) }
        model.addVillain(position: .btn, relative: .shorter, approxStack: 0)
        let btn = try XCTUnwrap(model.villains.first).id
        // Preflop: BTN first (after BB, wrapping), then SB hero
        model.add(action: .raise, toAmount: 2_600)
        model.add(action: .call, toAmount: 0)
        for c in PlayingCard.parseList("4h 3c Ad") { XCTAssertTrue(model.addBoardCard(c)) }
        model.add(action: .check, toAmount: 0)   // hero (SB first postflop)
        model.add(action: .check, toAmount: 0)   // BTN
        XCTAssertTrue(model.addBoardCard(PlayingCard("5h")!))
        model.add(action: .bet, toAmount: 1_500) // hero
        model.add(action: .call, toAmount: 0)    // BTN
        XCTAssertTrue(model.addBoardCard(PlayingCard("7h")!))
        model.add(action: .bet, toAmount: 500)    // hero
        model.add(action: .raise, toAmount: 3_500) // BTN
        model.add(action: .call, toAmount: 0)     // hero
        XCTAssertTrue(model.isHandOver)
        XCTAssertTrue(model.needsShowdown)
        model.setShownHolding(PlayingCard.parseList("Ah As"), for: btn)
        XCTAssertEqual(model.computedWinners, [.hero],
                       "straight beats trips — computedWinners returned \(model.computedWinners)")
        XCTAssertGreaterThan(model.heroNet, 0, "heroNet was \(model.heroNet)")
    }
}

// MARK: - Unknown-suit ("x") cards

final class UnknownSuitTests: XCTestCase {

    func testPlayingCardParsesUnknownSuit() throws {
        let card = try XCTUnwrap(PlayingCard("Kx"))
        XCTAssertEqual(card.rank, "K")
        XCTAssertEqual(card.suit, "x")
        XCTAssertTrue(card.hasUnknownSuit)
        XCTAssertEqual(card.raw, "Kx")
        XCTAssertEqual(card.display, "Kx")
        XCTAssertFalse(card.isRed)
        XCTAssertEqual(PlayingCard.parseList("Ac Kx").count, 2)
        XCTAssertNil(PlayingCard("Xx"))          // rank still validated
        XCTAssertNil(PlayingCard(rank: "K", suit: "y"))
    }

    @MainActor func testUnknownSuitCardsAreNeverDuplicates() throws {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 20_000)
        XCTAssertTrue(model.addCard(PlayingCard("Kx")!))
        XCTAssertTrue(model.addCard(PlayingCard("Kx")!))              // Kx Kx legal
        XCTAssertEqual(model.heroCards.count, 2)
    }

    @MainActor func testUnknownSuitAtShowdownRequiresManualWinner() throws {
        // Heads-up to showdown with an x in hero's hand: computedWinners must be
        // empty, isResolvable false until winnerOverride, then true.
        let model = HandCaptureModel(levelNumber: 21, smallBlind: 10_000, bigBlind: 25_000,
                                     ante: 25_000, heroCardCount: 2, heroStackBefore: 390_000)
        model.heroPosition = .btn
        XCTAssertTrue(model.addCard(PlayingCard("Ah")!))
        XCTAssertTrue(model.addCard(PlayingCard("Kx")!))
        model.addVillain(position: .utg, relative: .coversHero, approxStack: 0)
        let utg = model.villains.first!.id
        model.add(action: .allIn, toAmount: 390_000)  // UTG jams
        model.add(action: .call, toAmount: 0)          // hero calls
        for c in PlayingCard.parseList("Jh 8h 4d 2c 3s") { _ = model.addBoardCard(c) }
        model.setShownHolding(PlayingCard.parseList("Qs Qd"), for: utg)

        XCTAssertTrue(model.isHandOver)
        XCTAssertTrue(model.needsShowdown)
        XCTAssertTrue(model.computedWinners.isEmpty,
                      "x cards make the showdown unprovable — must never be guessed")
        XCTAssertFalse(model.isResolvable)
        model.winnerOverride = [.hero]
        XCTAssertTrue(model.isResolvable)
    }

    @MainActor func testFoldOutWithUnknownSuitResolvesNormally() throws {
        // Hero holds Kx, villain folds preflop: no showdown → resolvable as today.
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 20_000)
        model.heroPosition = .btn
        XCTAssertTrue(model.addCard(PlayingCard("Kx")!))
        XCTAssertTrue(model.addCard(PlayingCard("Kd")!))
        model.addVillain(position: .utg, relative: .similar, approxStack: 0)
        model.add(action: .fold, toAmount: 0)   // UTG folds preflop (acts first heads-up)
        XCTAssertTrue(model.isHandOver)
        XCTAssertFalse(model.needsShowdown)
        XCTAssertTrue(model.isResolvable)
    }
}

// MARK: - DemoData (screenshot demo mode)

final class AllInConversionTests: XCTestCase {

    /// Heads-up: hero BTN, one villain UTG (UTG acts first pre/postflop since
    /// neither seat is SB/BB — see `testCaptureTurnOrderAndPot`).
    @MainActor private func makeHeadsUpModel(heroStack: Int, villainApprox: Int = 0) -> HandCaptureModel {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: heroStack)
        model.heroPosition = .btn
        model.addVillain(position: .utg, relative: .similar, approxStack: villainApprox)
        return model
    }

    /// Three-handed: hero BTN, v1 UTG, v2 CO — preflop/postflop order (no
    /// SB/BB seated) is UTG, then CO, then BTN.
    @MainActor private func makeThreeWayModel(heroStack: Int, v1Approx: Int, v2Approx: Int) -> HandCaptureModel {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: heroStack)
        model.heroPosition = .btn
        model.addVillain(position: .utg, relative: .shorter, approxStack: v1Approx)
        model.addVillain(position: .co, relative: .coversHero, approxStack: v2Approx)
        return model
    }

    // THE reported bug: shove entered via Raise, called → board-only run-out.
    @MainActor func testShoveEnteredAsRaiseTriggersRunOut() throws {
        let model = makeHeadsUpModel(heroStack: 50_000)     // hero BTN, villain UTG approxStack 0
        model.add(action: .raise, toAmount: 6_000)          // villain (UTG acts first)
        model.add(action: .raise, toAmount: 50_000)         // hero — full stack: must convert
        XCTAssertTrue(model.allInParticipants.contains(.hero))
        model.add(action: .call, toAmount: 0)               // villain calls
        // Flop: cards owed, nobody to act
        XCTAssertEqual(model.boardCardsNeeded, 3)
        XCTAssertNil(model.participantToAct)
        for c in PlayingCard.parseList("Jh 8h 4d") { XCTAssertTrue(model.addBoardCard(c)) }
        XCTAssertNil(model.participantToAct)                // no turn betting
        XCTAssertEqual(model.boardCardsNeeded, 1)
        XCTAssertTrue(model.addBoardCard(try XCTUnwrap(PlayingCard("2c"))))
        XCTAssertNil(model.participantToAct)                // no river betting
        XCTAssertTrue(model.addBoardCard(try XCTUnwrap(PlayingCard("3s"))))
        XCTAssertTrue(model.isHandOver)
    }

    @MainActor func testCallForYourWholeStackConvertsToAllIn() {
        let model = makeHeadsUpModel(heroStack: 8_000)
        model.add(action: .raise, toAmount: 12_000)         // villain bets more than hero has
        model.add(action: .call, toAmount: 0)               // hero call = all-in for less
        XCTAssertTrue(model.allInParticipants.contains(.hero))
        // curBet must stay 12_000 (all-in for less does not reopen)
        XCTAssertEqual(model.currentBet, 12_000)
    }

    @MainActor func testVillainWithKnownStackConverts() {
        let model = makeHeadsUpModel(heroStack: 100_000, villainApprox: 30_000)
        model.add(action: .raise, toAmount: 30_000)         // villain raises entire stack
        XCTAssertEqual(model.allInParticipants.count, 1)    // villain converted
    }

    @MainActor func testVillainWithUnknownStackDoesNotConvert() {
        let model = makeHeadsUpModel(heroStack: 100_000)    // approxStack 0
        model.add(action: .raise, toAmount: 30_000)
        XCTAssertTrue(model.allInParticipants.isEmpty)
    }

    @MainActor func testMultiwaySidePotKeepsBetting() throws {
        // 3-handed: short villain jams, two big stacks call → flop betting continues.
        let model = makeThreeWayModel(heroStack: 100_000, v1Approx: 15_000, v2Approx: 90_000)
        let v1id = try XCTUnwrap(model.villains.first { $0.position == .utg }?.id)
        model.add(action: .raise, toAmount: 15_000)         // v1 (converted: whole stack)
        XCTAssertTrue(model.allInParticipants.contains(.villain(v1id)))
        model.add(action: .call, toAmount: 0)                // v2
        model.add(action: .call, toAmount: 0)                // hero
        for c in PlayingCard.parseList("Jh 8h 4d") { XCTAssertTrue(model.addBoardCard(c)) }
        XCTAssertNotNil(model.participantToAct)              // side-pot betting continues
        // Postflop order here is UTG (v1) → CO (v2) → BTN (hero); the all-in
        // v1 is excluded from further action, so participantToAct must not be them.
        XCTAssertNotEqual(model.participantToAct, .villain(v1id))
    }
}

// MARK: - DemoData (screenshot demo mode)

final class DemoDataSeedTests: XCTestCase {
    @MainActor func testDemoSeedPopulatesWorld() throws {
        let container = try makeInMemoryContainer()
        let ctx = container.mainContext
        DemoData.seed(into: ctx)
        let t = try XCTUnwrap(DemoData.activeTournament)
        XCTAssertEqual(t.status, .active)
        XCTAssertEqual((t.stackEntries ?? []).count, 13)
        XCTAssertEqual((t.hands ?? []).count, 5)
        XCTAssertEqual((t.handStubs ?? []).filter { $0.status == .pending }.count, 1)
        XCTAssertNotNil(DemoData.bigWinHand)
        let dictated = (t.hands ?? []).first { $0.sortedActions.isEmpty && !$0.notes.isEmpty }
        XCTAssertNotNil(dictated)
        let completed = try ctx.fetch(FetchDescriptor<Tournament>()).filter { $0.statusRaw == "completed" }
        XCTAssertEqual(completed.count, 8)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<CashSession>()).count, 3)
        DemoData.seed(into: ctx)   // idempotent
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Tournament>()).filter { $0.statusRaw == "completed" }.count, 8)
    }
}

// MARK: - Transcript editing (Task 1: TranscriptEditorSheet + entry points)

final class TranscriptEditingTests: XCTestCase {
    func testTranscriptMergeJoinsWithSingleSpace() {
        XCTAssertEqual(TranscriptMerge.joined(base: "I had aces ", newSpeech: " he called"),
                       "I had aces he called")
        XCTAssertEqual(TranscriptMerge.joined(base: "", newSpeech: "he called"), "he called")
        XCTAssertEqual(TranscriptMerge.joined(base: "I had aces", newSpeech: ""), "I had aces")
    }

    @MainActor func testEditedTranscriptPersistsThroughModel() {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 20_000)
        model.transcript = "original"
        model.transcript = "corrected text"
        XCTAssertTrue(model.canSave)          // transcript-only save stays enabled
        XCTAssertEqual(model.transcript, "corrected text")
    }

    @MainActor func testClearedTranscriptOnDictatedOnlyDisablesSave() {
        let model = HandCaptureModel(levelNumber: 1, smallBlind: 100, bigBlind: 200,
                                     ante: 0, heroCardCount: 2, heroStackBefore: 20_000)
        model.transcript = "spoken words"
        XCTAssertTrue(model.canSave)
        model.transcript = ""
        XCTAssertFalse(model.canSave)         // no structure + no transcript
    }
}
