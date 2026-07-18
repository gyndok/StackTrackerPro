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

func runPublish(files: [String], environment: String, execute: Bool, viaCktool: Bool) async throws {
    let utcDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    for file in files {
        let draft = try JSONDecoder().decode(EventDraft.self, from: Data(contentsOf: URL(fileURLWithPath: file)))

        // Validation
        var problems: [String] = []
        for (label, value) in [("tournamentName", draft.tournamentName), ("venueName", draft.venueName),
                               ("venueCity", draft.venueCity)] where value.isEmpty || value == "FILL ME IN" {
            problems.append("\(label) not filled in")
        }
        if draft.blindLevels.isEmpty { problems.append("no blind levels") }
        guard problems.isEmpty else {
            print("SKIP \(file): \(problems.joined(separator: "; "))")
            continue
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
            continue
        }
        var components = DateComponents()
        components.year = dayParts[0]; components.month = dayParts[1]; components.day = dayParts[2]
        components.hour = timeParts[0]; components.minute = timeParts[1]
        guard let eventDate = calendar.date(from: components) else {
            print("SKIP \(file): could not compose event date")
            continue
        }

        print("Geocoding \(draft.venueName), \(draft.venueCity), \(draft.venueState)…")
        guard let location = await geocode(name: draft.venueName, city: draft.venueCity, state: draft.venueState) else {
            print("SKIP \(file): could not geocode venue")
            continue
        }
        print("  → \(location.coordinate.latitude), \(location.coordinate.longitude)")

        // Dedup key must match the app exactly: venue|yyyy-MM-dd(UTC)|buyIn|gameType
        var dedupKey = "\(draft.venueName)|\(utcDay.string(from: eventDate))|\(draft.buyIn)|\(draft.gameTypeRaw)"
        if let suffix = draft.dedupSuffix, !suffix.isEmpty { dedupKey += "|\(suffix)" }

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
                print(process.terminationStatus == 0 ? "PUBLISHED \(draft.tournamentName)"
                                                     : "FAILED (exit \(process.terminationStatus)) — is a fresh USER token saved? (xcrun cktool save-token --type user)")
            } else {
                print("DRY RUN — would execute:")
                print("  xcrun " + args.joined(separator: " "))
                print("  fields: \(fieldsPath.path)")
            }
        } else {
            // Default path: CloudKit Web Services, signed with the
            // Server-to-Server key. No user token, no cktool shell-out.
            let subpath = wsSubpath(env: environment, operation: "modify")
            if execute {
                print("Publishing to \(environment) via CloudKit Web Services…")
                do {
                    let key = try loadS2SKey()
                    try await wsModifyRecords(env: environment, recordType: recordType, fields: fields, key: key)
                    print("PUBLISHED \(draft.tournamentName)")
                } catch {
                    print("FAILED: \(error)")
                }
            } else {
                print("DRY RUN — would POST to CloudKit Web Services:")
                print("  POST https://api.apple-cloudkit.com\(subpath)")
                print("  headers: X-Apple-CloudKit-Request-KeyID, X-Apple-CloudKit-Request-ISO8601Date, X-Apple-CloudKit-Request-SignatureV1")
                print("  fields: \(fieldsPath.path)")
            }
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
      seeder auth-check [--env development|production]
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
        var i = 1
        while i < arguments.count {
            switch arguments[i] {
            case "--env": environment = arguments[i + 1]; i += 2
            case "--execute": execute = true; i += 1
            case "--via-cktool": viaCktool = true; i += 1
            default: files.append(arguments[i]); i += 1
            }
        }
        guard !files.isEmpty else { throw Err("no event files") }
        try await runPublish(files: files, environment: environment, execute: execute, viaCktool: viaCktool)
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
    default:
        throw Err("unknown command: \(command)")
    }
} catch {
    print("error: \(error)")
    exit(1)
}
