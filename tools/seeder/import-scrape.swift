import Foundation
import CryptoKit

// Converts VegasPokerGuide scraper output (`tournaments.json` + `venues.json`)
// into one EventDraft JSON per event — the bulk alternative to `seeder parse`
// + hand-editing. See docs/superpowers/specs/2026-07-17-seeder-bulk-upgrades-design.md
// component 2 for the binding field-mapping rules.
//
//   seeder import-scrape <tournaments.json> --venues <venues.json> \
//       --from YYYY-MM-DD --to YYYY-MM-DD [--venue slug]... [--out drafts/] \
//       [--with-structures] [--include-day2]

// MARK: - Scraper input models

struct ScrapeReEntry: Codable {
    var type: String?
    var count: Int?
    var raw: String?
}

struct ScrapeEvent: Codable {
    var id: String
    var venue: String
    var date_pt: String
    var start_at_pt: String
    var game: String?
    var game_category: String?
    var event_name: String
    var buy_in_usd: Double?
    var guarantee_usd: Double?
    var re_entry: ScrapeReEntry?
    var is_day2: Bool?
    var structure_pdf_url: String?
    var starting_stack: Int?
    var level_minutes: String?
    var rake_usd: Double?
    var notes: String?
    /// PokerAtlas-fetcher addition (component 5): inline levels in the same
    /// shape as EventDraft.LevelDraft. When present, wins over
    /// structure_pdf_url — no PDF to download.
    var structure_levels: [EventDraft.LevelDraft]?
}

struct ScrapeTournamentsFile: Codable {
    var generated_at: String?
    var source_sheet_updated_at: String?
    var tournaments: [ScrapeEvent]
}

struct ScrapeVenue: Codable {
    var slug: String
    var display_name: String
    var series_name: String?
    var address: String?
    var override_per_event_url: Bool?
    /// IANA timezone override (e.g. "America/Chicago" for PokerAtlas Texas
    /// venues). Takes precedence over `venueTimeZones`/the Vegas-default
    /// fallback below when present.
    var timezone: String?
}

struct ScrapeVenuesFile: Codable {
    var venues: [ScrapeVenue]
}

// MARK: - Venue loading (JSON preferred; minimal .yml grep fallback)

/// Loads venues from either `venues.json` (preferred — full fidelity) or a
/// `.yml`/`.yaml` file, parsed with a grep-grade line scanner that only
/// understands flat `key: value` pairs inside `- slug: ...` blocks. The YAML
/// path exists solely so a hand-maintained venues.yml (e.g. carrying
/// `override_per_event_url` overrides) can be dropped in without a full YAML
/// parser dependency — prefer JSON whenever possible.
func loadVenues(path: String) throws -> [ScrapeVenue] {
    let url = URL(fileURLWithPath: path)
    let ext = url.pathExtension.lowercased()
    if ext == "yml" || ext == "yaml" {
        return try loadVenuesFromYAMLGrep(path: path)
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(ScrapeVenuesFile.self, from: data).venues
}

func loadVenuesFromYAMLGrep(path: String) throws -> [ScrapeVenue] {
    let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    var venues: [ScrapeVenue] = []
    var current: [String: String] = [:]

    func flush() {
        guard let slug = current["slug"] else { return }
        venues.append(ScrapeVenue(
            slug: slug,
            display_name: current["display_name"] ?? slug,
            series_name: current["series_name"],
            address: current["address"],
            override_per_event_url: current["override_per_event_url"] == "true",
            timezone: current["timezone"]
        ))
        current = [:]
    }

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        var line = String(rawLine)
        let trimmedForDash = line.trimmingCharacters(in: .whitespaces)
        if trimmedForDash.hasPrefix("- slug:") || trimmedForDash.hasPrefix("-slug:") {
            flush()
            if let dashRange = line.range(of: "- ") {
                line.removeSubrange(dashRange)
            }
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }
        let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { continue }
        var value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        current[key] = value
    }
    flush()
    return venues
}

// MARK: - Field mapping (spec component 2, binding)

/// City/state from the venue address's last two comma segments; state is the
/// 2-letter token at the start of the final segment (e.g. "NV" of "NV 89109").
func cityState(fromAddress address: String?) -> (city: String, state: String) {
    guard let address = address else { return ("", "") }
    let parts = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count >= 2 else { return ("", "") }
    let city = parts[parts.count - 2]
    let lastSegment = parts[parts.count - 1]
    let state = lastSegment.split(separator: " ").first.map(String.init) ?? ""
    return (city, state)
}

func mappedGameTypeRaw(_ event: ScrapeEvent) -> String {
    switch (event.game_category ?? "").lowercased() {
    case "nlh": return "NLH"
    case "plo": return "PLO"
    default: return event.game ?? ""
    }
}

func mappedReentryPolicy(_ reEntry: ScrapeReEntry?) -> String {
    guard let reEntry = reEntry else { return "None" }
    switch reEntry.type {
    case "unlimited": return "Unlimited"
    case "none": return "None"
    default:
        if let count = reEntry.count { return String(count) }
        return "None"
    }
}

/// Trailing flight token of the scraper id (e.g. "...-nlh-1a" -> "1A") when
/// it matches ^\d+[a-z]$ case-insensitively; nil (omitted) otherwise.
func mappedDedupSuffix(fromID id: String) -> String? {
    guard let lastToken = id.split(separator: "-").last else { return nil }
    let token = String(lastToken)
    guard let regex = try? NSRegularExpression(pattern: #"^\d+[a-z]$"#, options: [.caseInsensitive]) else { return nil }
    let range = NSRange(token.startIndex..<token.endIndex, in: token)
    guard regex.firstMatch(in: token, options: [], range: range) != nil else { return nil }
    return token.uppercased()
}

/// HH:mm extracted from start_at_pt AS WRITTEN — it's already venue-local
/// with its own UTC offset, so no timezone math here.
func mappedStartTimeLocal(fromStartAtPT startAtPT: String) -> String? {
    guard let tIndex = startAtPT.firstIndex(of: "T") else { return nil }
    let after = startAtPT[startAtPT.index(after: tIndex)...]
    guard after.count >= 5 else { return nil }
    return String(after.prefix(5))
}

/// Per-venue IANA timezone map for sources that don't carry their own
/// per-venue `timezone` (every VegasPokerGuide venue is Las Vegas/Pacific,
/// so the default covers those). A non-Vegas source's venues file (e.g.
/// PokerAtlas Texas's tx-venues.yml, component 5) carries its own
/// `timezone` field per venue, which wins when present.
let venueTimeZones: [String: String] = [:]
func mappedTimeZone(forVenueSlug slug: String, venueTimeZone: String?) -> String {
    venueTimeZone ?? venueTimeZones[slug] ?? "America/Los_Angeles"
}

func mappedBuyInAndFee(_ event: ScrapeEvent) -> (buyIn: Int, entryFee: Int) {
    let total = Int((event.buy_in_usd ?? 0).rounded())
    guard let rake = event.rake_usd else { return (total, 0) }
    let roundedRake = Int(rake.rounded())
    return (total - roundedRake, roundedRake)
}

/// `<venue-slug>-<date_pt>-<last-id-token>.json`
func outputFilename(forEvent event: ScrapeEvent) -> String {
    let lastToken = event.id.split(separator: "-").last.map(String.init) ?? event.id
    return "\(event.venue)-\(event.date_pt)-\(lastToken).json"
}

func makeDraft(event: ScrapeEvent, venue: ScrapeVenue?) -> EventDraft {
    let (city, state) = cityState(fromAddress: venue?.address)
    var name = event.event_name
    if let series = venue?.series_name, !series.isEmpty, !event.event_name.contains(series) {
        name = "\(series) — \(event.event_name)"
    }
    let (buyIn, entryFee) = mappedBuyInAndFee(event)
    return EventDraft(
        tournamentName: name,
        venueName: venue?.display_name ?? event.venue,
        venueCity: city,
        venueState: state,
        gameTypeRaw: mappedGameTypeRaw(event),
        buyIn: buyIn,
        entryFee: entryFee,
        bountyAmount: 0,
        guarantee: Int((event.guarantee_usd ?? 0).rounded()),
        startingChips: event.starting_stack ?? 0,
        reentryPolicy: mappedReentryPolicy(event.re_entry),
        eventDate: event.date_pt,
        startingSB: 0,
        startingBB: 0,
        dedupSuffix: mappedDedupSuffix(fromID: event.id),
        startTimeLocal: mappedStartTimeLocal(fromStartAtPT: event.start_at_pt),
        timeZone: mappedTimeZone(forVenueSlug: event.venue, venueTimeZone: venue?.timezone),
        blindLevels: []
    )
}

// MARK: - --with-structures: PDF download + shared parse pipeline

/// Synchronous download to `destination`, skipping when already cached.
func downloadPDFSync(from urlString: String, to destination: URL) throws {
    guard let url = URL(string: urlString) else { throw Err("invalid structure_pdf_url: \(urlString)") }
    if FileManager.default.fileExists(atPath: destination.path) { return }
    try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

    let semaphore = DispatchSemaphore(value: 0)
    var thrown: Error?
    let task = URLSession.shared.downloadTask(with: url) { tempURL, _, error in
        defer { semaphore.signal() }
        if let error = error { thrown = error; return }
        guard let tempURL = tempURL else { thrown = Err("no data downloading \(urlString)"); return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            thrown = error
        }
    }
    task.resume()
    semaphore.wait()
    if let thrown = thrown { throw thrown }
}

/// Downloads (cached by sha256 of the URL under `.pdfcache/`) and runs the
/// same parse path `runParse` uses, returning levels in EventDraft shape.
func structureLevels(fromPDFURL urlString: String) throws -> [EventDraft.LevelDraft] {
    let hash = SHA256.hash(data: Data(urlString.utf8)).map { String(format: "%02x", $0) }.joined()
    let cachePath = URL(fileURLWithPath: ".pdfcache").appendingPathComponent("\(hash).pdf")
    try downloadPDFSync(from: urlString, to: cachePath)
    let lines = try linesFromFile(cachePath.path)
    let levels = BlindStructureParser.normalizeDurations(BlindStructureParser.parseBlindLevels(from: lines))
    return levels.map {
        EventDraft.LevelDraft(
            levelNumber: $0.levelNumber, smallBlind: $0.smallBlind, bigBlind: $0.bigBlind,
            ante: $0.ante, durationMinutes: $0.durationMinutes, isBreak: $0.isBreak,
            breakLabel: $0.breakLabel
        )
    }
}

// MARK: - import-scrape command

func runImportScrape(args: [String]) throws {
    var tournamentsPath: String?
    var venuesPath: String?
    var fromDate: String?
    var toDate: String?
    var venueFilter: Set<String> = []
    var outDir = "drafts"
    var withStructures = false
    var includeDay2 = false

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--venues":
            guard i + 1 < args.count else { throw Err("--venues requires a path") }
            venuesPath = args[i + 1]; i += 2
        case "--from":
            guard i + 1 < args.count else { throw Err("--from requires YYYY-MM-DD") }
            fromDate = args[i + 1]; i += 2
        case "--to":
            guard i + 1 < args.count else { throw Err("--to requires YYYY-MM-DD") }
            toDate = args[i + 1]; i += 2
        case "--venue":
            guard i + 1 < args.count else { throw Err("--venue requires a slug") }
            venueFilter.insert(args[i + 1]); i += 2
        case "--out":
            guard i + 1 < args.count else { throw Err("--out requires a path") }
            outDir = args[i + 1]; i += 2
        case "--with-structures":
            withStructures = true; i += 1
        case "--include-day2":
            includeDay2 = true; i += 1
        default:
            tournamentsPath = args[i]; i += 1
        }
    }

    guard let tournamentsPath = tournamentsPath else { throw Err("usage: seeder import-scrape <tournaments.json> --venues <venues.json> --from YYYY-MM-DD --to YYYY-MM-DD") }
    guard let venuesPath = venuesPath else { throw Err("--venues <venues.json> is required") }

    let tournaments = try JSONDecoder().decode(
        ScrapeTournamentsFile.self, from: Data(contentsOf: URL(fileURLWithPath: tournamentsPath))
    ).tournaments
    let venuesBySlug = Dictionary(uniqueKeysWithValues: try loadVenues(path: venuesPath).map { ($0.slug, $0) })

    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    var emitted = 0
    var skippedDay2 = 0
    var structuresAttached = 0
    var structureWarnings = 0
    var venueWarnings = 0

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    for event in tournaments {
        if let from = fromDate, event.date_pt < from { continue }
        if let to = toDate, event.date_pt > to { continue }
        if !venueFilter.isEmpty && !venueFilter.contains(event.venue) { continue }

        if event.is_day2 == true && !includeDay2 {
            skippedDay2 += 1
            continue
        }

        let venue = venuesBySlug[event.venue]
        var draft = makeDraft(event: event, venue: venue)

        // "Failures loud, never silently empty": a draft with an empty
        // city/state still gets emitted (publish's validation is the real
        // gate), but never without saying why.
        if venue == nil {
            print("WARNING: \(event.id) — venue slug '\(event.venue)' not found in venues file; venueName falls back to the raw slug and venueCity/venueState are empty")
            venueWarnings += 1
        } else if draft.venueCity.isEmpty || draft.venueState.isEmpty {
            let address = venue?.address ?? "(missing)"
            print("WARNING: \(event.id) — venue '\(event.venue)' address '\(address)' does not parse into city/state (need at least two comma-separated segments); venueCity/venueState are empty")
            venueWarnings += 1
        }

        if let inline = event.structure_levels, !inline.isEmpty {
            // PokerAtlas-fetcher inline levels win over structure_pdf_url.
            draft.blindLevels = inline
            if let first = inline.first(where: { !$0.isBreak }) {
                draft.startingSB = first.smallBlind
                draft.startingBB = first.bigBlind
            }
            structuresAttached += 1
        } else if withStructures, let pdfURL = event.structure_pdf_url {
            if venue?.override_per_event_url == true {
                print("NOTICE: \(event.id) — venue '\(event.venue)' uses an overridden per-event PDF bundle; skipping structure attachment")
            } else {
                do {
                    let levels = try structureLevels(fromPDFURL: pdfURL)
                    let nonBreak = levels.filter { !$0.isBreak }
                    if nonBreak.count >= 8 {
                        draft.blindLevels = levels
                        if let first = nonBreak.first {
                            draft.startingSB = first.smallBlind
                            draft.startingBB = first.bigBlind
                        }
                        structuresAttached += 1
                    } else {
                        print("WARNING: \(event.id) — structure parse yielded only \(nonBreak.count) level(s) (<8 required); leaving blindLevels empty")
                        structureWarnings += 1
                    }
                } catch {
                    print("WARNING: \(event.id) — structure parse failed: \(error)")
                    structureWarnings += 1
                }
            }
        }

        let filename = outputFilename(forEvent: event)
        let outPath = (outDir as NSString).appendingPathComponent(filename)
        let data = try encoder.encode(draft)
        try data.write(to: URL(fileURLWithPath: outPath))
        emitted += 1
    }

    print("emitted \(emitted), skipped-day2 \(skippedDay2), structures-attached \(structuresAttached), structure-warnings \(structureWarnings), venue-warnings \(venueWarnings)")
}
