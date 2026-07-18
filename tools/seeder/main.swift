import Foundation
import PDFKit
import Vision
import AppKit
import CoreLocation
import MapKit

// StackTrackerPro community-tournament seeding CLI.
//
//   seeder parse <pdf-or-image>... --out event.json
//       OCRs structure sheets / Poker Atlas screenshots with the app's
//       exact pipeline and writes an editable event-draft JSON.
//
//   seeder publish <event.json>... [--env development|production] [--execute]
//       Geocodes the venue, builds the SharedTournament record, and calls
//       `xcrun cktool create-record`. Dry-run by default; --execute saves.
//
// Compiles against the app's own BlindStructureParsing.swift (see build.sh),
// so structure parsing can never drift from what the app does.

// MARK: - Constants (match the app)

let teamID = "NJ4JGW72MW"
let containerID = "iCloud.com.gyndok.stacktrackerpro"
let recordType = "SharedTournament"

// MARK: - Event draft model

struct EventDraft: Codable {
    var tournamentName: String
    var venueName: String
    var venueCity: String
    var venueState: String
    var gameTypeRaw: String
    var buyIn: Int
    var entryFee: Int
    var bountyAmount: Int
    var guarantee: Int
    var startingChips: Int
    var reentryPolicy: String
    /// Event day, "yyyy-MM-dd" (local to the venue). Stored as noon UTC so
    /// the app's UTC-day browser window matches regardless of timezone.
    var eventDate: String
    var startingSB: Int
    var startingBB: Int
    /// Optional discriminator appended to the dedup key (e.g. "1C"/"1D")
    /// so same-day flights of one event don't collapse in the browser.
    var dedupSuffix: String?
    /// Venue-local start time "HH:mm" (24h). Stored into eventDate so the
    /// browser shows the real start; defaults to noon when absent.
    var startTimeLocal: String?
    /// IANA timezone for startTimeLocal (default America/Los_Angeles).
    var timeZone: String?
    var blindLevels: [LevelDraft]

    struct LevelDraft: Codable {
        var levelNumber: Int
        var smallBlind: Int
        var bigBlind: Int
        var ante: Int
        var durationMinutes: Int
        var isBreak: Bool
        var breakLabel: String?
    }
}

// MARK: - OCR (mirrors PokerAtlasScanner: 3x render, accurate, row grouping)

struct Obs { let text: String; let box: CGRect }

func ocr(_ cgImage: CGImage) throws -> [Obs] {
    var result: [Obs] = []
    let request = VNRecognizeTextRequest { req, _ in
        guard let observations = req.results as? [VNRecognizedTextObservation] else { return }
        result = observations.compactMap { o in
            guard let c = o.topCandidates(1).first else { return nil }
            return Obs(text: c.string, box: o.boundingBox)
        }
    }
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
    return result
}

func groupIntoRows(_ observations: [Obs]) -> [String] {
    guard !observations.isEmpty else { return [] }
    let sorted = observations.sorted { $0.box.midY > $1.box.midY }
    var rows: [[Obs]] = []
    var currentRow: [Obs] = []
    var currentMidY: CGFloat = -1
    let threshold: CGFloat = 0.01
    for obs in sorted {
        let midY = obs.box.midY
        if currentRow.isEmpty {
            currentRow.append(obs); currentMidY = midY
        } else if abs(midY - currentMidY) < threshold {
            currentRow.append(obs)
            let sum = currentRow.reduce(CGFloat(0)) { $0 + $1.box.midY }
            currentMidY = sum / CGFloat(currentRow.count)
        } else {
            currentRow.sort { $0.box.origin.x < $1.box.origin.x }
            rows.append(currentRow)
            currentRow = [obs]; currentMidY = midY
        }
    }
    if !currentRow.isEmpty {
        currentRow.sort { $0.box.origin.x < $1.box.origin.x }
        rows.append(currentRow)
    }
    return rows.map { $0.map(\.text).joined(separator: " ") }
}

func linesFromFile(_ path: String) throws -> [String] {
    let url = URL(fileURLWithPath: path)
    var lines: [String] = []
    if url.pathExtension.lowercased() == "pdf" {
        guard let doc = PDFDocument(url: url) else { throw Err("cannot open PDF: \(path)") }
        for i in 0..<min(doc.pageCount, 6) {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let size = CGSize(width: bounds.width * 3, height: bounds.height * 3)
            let image = page.thumbnail(of: size, for: .mediaBox)
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            lines += groupIntoRows(try ocr(cg))
        }
    } else {
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Err("cannot open image: \(path)")
        }
        lines += groupIntoRows(try ocr(cg))
    }
    return lines
}

struct Err: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - parse command

func runParse(files: [String], outPath: String) throws {
    var allLines: [String] = []
    for file in files {
        print("OCR: \(file)")
        allLines += try linesFromFile(file)
    }

    let levels = BlindStructureParser.normalizeDurations(
        BlindStructureParser.parseBlindLevels(from: allLines)
    )
    print("Parsed \(levels.filter { !$0.isBreak }.count) levels (+\(levels.filter(\.isBreak).count) breaks)")

    // Best-effort metadata; the draft is meant to be reviewed by hand.
    let joined = allLines.joined(separator: "\n")
    func firstIntMatch(_ pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: joined, range: NSRange(joined.startIndex..., in: joined)),
              let r = Range(m.range(at: 1), in: joined) else { return nil }
        return Int(joined[r].replacingOccurrences(of: ",", with: ""))
    }

    let name = allLines.first { $0.uppercased().contains("EVENT") || $0.lowercased().contains("tournament") }
        ?? "FILL ME IN"
    let startingChips = firstIntMatch(#"starting\s+(?:chips|stack)[:\s]*(\d[\d,]*)"#) ?? 0
    let buyIn = firstIntMatch(#"\$\s*(\d[\d,]*)"#) ?? 0
    let guarantee = firstIntMatch(#"(\d[\d,]*)\s*(?:gtd|guaranteed)"#) ?? 0

    let today = ISO8601DateFormatter().string(from: Date()).prefix(10)

    let draft = EventDraft(
        tournamentName: name.trimmingCharacters(in: .whitespaces),
        venueName: "FILL ME IN",
        venueCity: "FILL ME IN",
        venueState: "TX",
        gameTypeRaw: "NLH",
        buyIn: buyIn,
        entryFee: 0,
        bountyAmount: 0,
        guarantee: guarantee,
        startingChips: startingChips,
        reentryPolicy: "None",
        eventDate: String(today),
        startingSB: levels.first(where: { !$0.isBreak })?.smallBlind ?? 0,
        startingBB: levels.first(where: { !$0.isBreak })?.bigBlind ?? 0,
        blindLevels: levels.map {
            EventDraft.LevelDraft(
                levelNumber: $0.levelNumber, smallBlind: $0.smallBlind,
                bigBlind: $0.bigBlind, ante: $0.ante,
                durationMinutes: $0.durationMinutes, isBreak: $0.isBreak,
                breakLabel: $0.breakLabel
            )
        }
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(draft).write(to: URL(fileURLWithPath: outPath))
    print("Draft written to \(outPath) — review the FILL ME IN fields and eventDate before publishing.")
}

// MARK: - publish command

func geocode(name: String, city: String, state: String) async -> CLLocation? {
    // Same MapKit natural-language search the app's LocationManager uses.
    let address = [name, city, state].filter { !$0.isEmpty && $0 != "FILL ME IN" }
        .joined(separator: ", ")
    guard !address.isEmpty else { return nil }
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = address
    guard let response = try? await MKLocalSearch(request: request).start(),
          let item = response.mapItems.first else { return nil }
    let coord = item.location.coordinate
    return CLLocation(latitude: coord.latitude, longitude: coord.longitude)
}

enum PublishOutcome { case published, skipped }

/// Publishes (or dry-runs) a single draft file. Returns whether it was
/// published/dry-run-printed or skipped by validation/dedup; throws (never
/// prints and swallows) on any hard failure so the caller can count it and
/// report it loudly.
func publishOne(
    file: String, environment: String, execute: Bool, viaCktool: Bool,
    skipExisting: Bool, allowEmptyStructure: Bool, utcDay: DateFormatter
) async throws -> PublishOutcome {
    let draft = try JSONDecoder().decode(EventDraft.self, from: Data(contentsOf: URL(fileURLWithPath: file)))

    // Validation
    var problems: [String] = []
    for (label, value) in [("tournamentName", draft.tournamentName), ("venueName", draft.venueName),
                           ("venueCity", draft.venueCity)] where value.isEmpty || value == "FILL ME IN" {
        problems.append("\(label) not filled in")
    }
    var warnings: [String] = []
    if draft.blindLevels.isEmpty {
        if allowEmptyStructure {
            warnings.append("no blind levels — publishing a metadata-only listing")
        } else {
            problems.append("no blind levels")
        }
    }
    guard problems.isEmpty else {
        print("SKIP \(file): \(problems.joined(separator: "; "))")
        return .skipped
    }
    for warning in warnings {
        print("WARNING \(file): \(warning)")
    }

    // Event date at the venue-local start time (the app windows the
    // browser by the viewer's local day and displays this time).
    let zone = TimeZone(identifier: draft.timeZone ?? "America/Los_Angeles") ?? TimeZone(identifier: "UTC")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let dayParts = draft.eventDate.split(separator: "-").compactMap { Int($0) }
    let timeParts = (draft.startTimeLocal ?? "12:00").split(separator: ":").compactMap { Int($0) }
    guard dayParts.count == 3, timeParts.count == 2 else {
        print("SKIP \(file): eventDate must be yyyy-MM-dd and startTimeLocal HH:mm")
        return .skipped
    }
    var components = DateComponents()
    components.year = dayParts[0]; components.month = dayParts[1]; components.day = dayParts[2]
    components.hour = timeParts[0]; components.minute = timeParts[1]
    guard let eventDate = calendar.date(from: components) else {
        print("SKIP \(file): could not compose event date")
        return .skipped
    }

    print("Geocoding \(draft.venueName), \(draft.venueCity), \(draft.venueState)…")
    guard let location = await geocode(name: draft.venueName, city: draft.venueCity, state: draft.venueState) else {
        print("SKIP \(file): could not geocode venue")
        return .skipped
    }
    print("  → \(location.coordinate.latitude), \(location.coordinate.longitude)")

    // Dedup key must match the app exactly: venue|yyyy-MM-dd(UTC)|buyIn|gameType
    var dedupKey = "\(draft.venueName)|\(utcDay.string(from: eventDate))|\(draft.buyIn)|\(draft.gameTypeRaw)"
    if let suffix = draft.dedupSuffix, !suffix.isEmpty { dedupKey += "|\(suffix)" }

    // --skip-existing only works on the CloudKit Web Services path (the
    // cktool fallback prints one global notice up front and is a no-op
    // here — see runPublish).
    var s2sKey: S2SKey?
    if !viaCktool && execute {
        s2sKey = try loadS2SKey()
    }
    if skipExisting && !viaCktool {
        if execute, let key = s2sKey {
            if try await wsQueryByDedupKey(env: environment, dedupKey: dedupKey, key: key) {
                print("SKIP \(file): already published (\(dedupKey))")
                return .skipped
            }
        } else if !execute {
            print("DRY RUN — --skip-existing would check CloudKit Web Services for dedupKey \(dedupKey)")
        }
    }

    let levelsJSON: String = {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(draft.blindLevels),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }()

    let iso = ISO8601DateFormatter()
    func f(_ type: String, _ value: Any) -> [String: Any] { ["type": type, "value": value] }
    let fields: [String: Any] = [
        "tournamentName": f("stringType", draft.tournamentName),
        "venueName": f("stringType", draft.venueName),
        "venueCity": f("stringType", draft.venueCity),
        "venueState": f("stringType", draft.venueState),
        "gameTypeRaw": f("stringType", draft.gameTypeRaw),
        "buyIn": f("int64Type", draft.buyIn),
        "entryFee": f("int64Type", draft.entryFee),
        "bountyAmount": f("int64Type", draft.bountyAmount),
        "guarantee": f("int64Type", draft.guarantee),
        "startingChips": f("int64Type", draft.startingChips),
        "startingSB": f("int64Type", draft.startingSB),
        "startingBB": f("int64Type", draft.startingBB),
        "reentryPolicy": f("stringType", draft.reentryPolicy),
        "eventDate": f("timestampType", iso.string(from: eventDate)),
        "latitude": f("doubleType", location.coordinate.latitude),
        "longitude": f("doubleType", location.coordinate.longitude),
        "blindLevelsJSON": f("stringType", levelsJSON),
        "deduplicationKey": f("stringType", dedupKey),
        "contributedAt": f("timestampType", iso.string(from: Date()))
    ]
    let fieldsData = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    let fieldsPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("seeder-fields-\(UUID().uuidString).json")
    try fieldsData.write(to: fieldsPath)

    if viaCktool {
        let args = ["cktool", "create-record",
                    "--team-id", teamID,
                    "--container-id", containerID,
                    "--environment", environment,
                    "--database-type", "public",
                    "--record-type", recordType,
                    "--fields-file", fieldsPath.path]

        if execute {
            print("Publishing to \(environment) via cktool…")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = args
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw Err("cktool create-record exited \(process.terminationStatus) — is a fresh USER token saved? (xcrun cktool save-token --type user)")
            }
            print("PUBLISHED \(draft.tournamentName)")
        } else {
            print("DRY RUN — would execute:")
            print("  xcrun " + args.joined(separator: " "))
            print("  fields: \(fieldsPath.path)")
        }
    } else {
        // Default path: CloudKit Web Services, signed with the
        // Server-to-Server key. No user token, no cktool shell-out.
        let subpath = wsSubpath(env: environment, operation: "modify")
        if execute, let key = s2sKey {
            print("Publishing to \(environment) via CloudKit Web Services…")
            try await wsModifyRecords(env: environment, recordType: recordType, fields: fields, key: key)
            print("PUBLISHED \(draft.tournamentName)")
        } else {
            print("DRY RUN — would POST to CloudKit Web Services:")
            print("  POST https://api.apple-cloudkit.com\(subpath)")
            print("  headers: X-Apple-CloudKit-Request-KeyID, X-Apple-CloudKit-Request-ISO8601Date, X-Apple-CloudKit-Request-SignatureV1")
            print("  fields: \(fieldsPath.path)")
        }
    }
    return .published
}

func runPublish(
    files: [String], environment: String, execute: Bool, viaCktool: Bool,
    skipExisting: Bool, allowEmptyStructure: Bool
) async throws {
    let utcDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    if skipExisting && viaCktool {
        print("NOTICE: --skip-existing requires the CloudKit Web Services path; it has no effect with --via-cktool — the duplicate check is skipped for this run.")
    }

    var publishedCount = 0
    var skippedCount = 0
    var failedCount = 0

    for file in files {
        do {
            let outcome = try await publishOne(
                file: file, environment: environment, execute: execute, viaCktool: viaCktool,
                skipExisting: skipExisting, allowEmptyStructure: allowEmptyStructure, utcDay: utcDay
            )
            switch outcome {
            case .published: publishedCount += 1
            case .skipped: skippedCount += 1
            }
        } catch {
            failedCount += 1
            print("FAIL \(file): \(error)")
        }
    }

    print("published \(publishedCount), skipped \(skippedCount), failed \(failedCount)")
    if failedCount > 0 {
        exit(1)
    }
}

// MARK: - clone command

/// Strips a trailing `-yyyy-MM-dd` from a file's basename (keeping its
/// extension and directory) and appends `newDate` in its place.
func cloneOutputPath(inputPath: String, newDate: String) -> String {
    let url = URL(fileURLWithPath: inputPath)
    let ext = url.pathExtension.isEmpty ? "json" : url.pathExtension
    let base = url.deletingPathExtension().lastPathComponent
    let strippedBase = base.replacingOccurrences(
        of: #"-\d{4}-\d{2}-\d{2}$"#, with: "", options: .regularExpression
    )
    let newName = "\(strippedBase)-\(newDate).\(ext)"
    return url.deletingLastPathComponent().appendingPathComponent(newName).path
}

func runClone(arguments: [String]) throws {
    var inputFile: String?
    var date: String?
    var repeatInterval: String?
    var until: String?
    var suffix: String?
    var time: String?
    var name: String?

    var i = 0
    while i < arguments.count {
        func value() throws -> String {
            guard i + 1 < arguments.count else { throw Err("\(arguments[i]) requires a value") }
            return arguments[i + 1]
        }
        switch arguments[i] {
        case "--date": date = try value(); i += 2
        case "--repeat": repeatInterval = try value(); i += 2
        case "--until": until = try value(); i += 2
        case "--suffix": suffix = try value(); i += 2
        case "--time": time = try value(); i += 2
        case "--name": name = try value(); i += 2
        default:
            guard inputFile == nil else { throw Err("unexpected argument: \(arguments[i])") }
            inputFile = arguments[i]; i += 1
        }
    }

    guard let inputFile else { throw Err("clone requires an input event.json file") }
    guard date == nil || repeatInterval == nil else {
        throw Err("--repeat and --date are mutually exclusive")
    }
    guard date != nil || repeatInterval != nil else {
        throw Err("clone requires either --date or --repeat weekly --until")
    }
    if let repeatInterval {
        guard repeatInterval == "weekly" else {
            throw Err("only --repeat weekly is supported")
        }
        guard until != nil else {
            throw Err("--repeat weekly requires --until YYYY-MM-DD")
        }
    }

    let draft = try JSONDecoder().decode(EventDraft.self, from: Data(contentsOf: URL(fileURLWithPath: inputFile)))
    let zone = TimeZone(identifier: draft.timeZone ?? "America/Los_Angeles") ?? TimeZone(identifier: "UTC")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone

    func dateAtNoon(_ yyyyMMdd: String) throws -> Date {
        let parts = yyyyMMdd.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { throw Err("date must be yyyy-MM-dd: \(yyyyMMdd)") }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        comps.hour = 12; comps.minute = 0
        guard let composed = calendar.date(from: comps) else {
            throw Err("could not compose date: \(yyyyMMdd)")
        }
        return composed
    }

    func formatDate(_ d: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = zone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: d)
    }

    func writeClone(eventDateString: String) throws {
        var newDraft = draft
        newDraft.eventDate = eventDateString
        if let name { newDraft.tournamentName = name }
        if let suffix { newDraft.dedupSuffix = suffix }
        if let time { newDraft.startTimeLocal = time }

        let outPath = cloneOutputPath(inputPath: inputFile, newDate: eventDateString)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(newDraft).write(to: URL(fileURLWithPath: outPath))
        print(outPath)
    }

    if let date {
        guard date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw Err("--date must be yyyy-MM-dd: \(date)")
        }
        try writeClone(eventDateString: date)
    } else {
        // Weekly recurrence: first occurrence strictly after the template's
        // eventDate, through --until inclusive, on the template's weekday.
        // Date math stays in the draft's own Calendar/TimeZone (adding
        // whole days via the calendar, not raw 7*86400 seconds) so DST
        // transitions never shift the emitted weekday.
        let templateDate = try dateAtNoon(draft.eventDate)
        let untilDate = try dateAtNoon(until!)
        var current = calendar.date(byAdding: .day, value: 7, to: templateDate)!
        while current <= untilDate {
            try writeClone(eventDateString: formatDate(current))
            current = calendar.date(byAdding: .day, value: 7, to: current)!
        }
    }
}

// MARK: - main

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print("""
    usage:
      seeder parse <pdf-or-image>... --out <event.json>
      seeder publish <event.json>... [--env development|production] [--execute] [--via-cktool]
                      [--skip-existing] [--allow-empty-structure]
      seeder auth-check [--env development|production]
      seeder import-scrape <tournaments.json> --venues <venues.json> --from YYYY-MM-DD --to YYYY-MM-DD
                            [--venue slug]... [--out drafts/] [--with-structures] [--include-day2]
      seeder clone <event.json> (--date YYYY-MM-DD | --repeat weekly --until YYYY-MM-DD)
                   [--suffix S] [--time HH:mm] [--name N]
    """)
    exit(1)
}

do {
    switch command {
    case "parse":
        var files: [String] = []
        var out = "event.json"
        var i = 1
        while i < arguments.count {
            if arguments[i] == "--out", i + 1 < arguments.count {
                out = arguments[i + 1]; i += 2
            } else {
                files.append(arguments[i]); i += 1
            }
        }
        guard !files.isEmpty else { throw Err("no input files") }
        try runParse(files: files, outPath: out)
    case "publish":
        var files: [String] = []
        var environment = "development"
        var execute = false
        var viaCktool = false
        var skipExisting = false
        var allowEmptyStructure = false
        var i = 1
        while i < arguments.count {
            switch arguments[i] {
            case "--env": environment = arguments[i + 1]; i += 2
            case "--execute": execute = true; i += 1
            case "--via-cktool": viaCktool = true; i += 1
            case "--skip-existing": skipExisting = true; i += 1
            case "--allow-empty-structure": allowEmptyStructure = true; i += 1
            default: files.append(arguments[i]); i += 1
            }
        }
        guard !files.isEmpty else { throw Err("no event files") }
        try await runPublish(
            files: files, environment: environment, execute: execute, viaCktool: viaCktool,
            skipExisting: skipExisting, allowEmptyStructure: allowEmptyStructure
        )
    case "auth-check":
        var environment = "development"
        var i = 1
        while i < arguments.count {
            switch arguments[i] {
            case "--env": environment = arguments[i + 1]; i += 2
            default: i += 1
            }
        }
        try await runAuthCheck(environment: environment)
    case "import-scrape":
        try runImportScrape(args: Array(arguments.dropFirst()))
    case "clone":
        try runClone(arguments: Array(arguments.dropFirst()))
    default:
        throw Err("unknown command: \(command)")
    }
} catch {
    print("error: \(error)")
    exit(1)
}
