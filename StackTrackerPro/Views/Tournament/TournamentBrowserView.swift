import SwiftUI
import CoreLocation

// MARK: - Buy-In Range

enum BuyInRange: String, CaseIterable {
    case any = "Any Buy-in"
    case under100 = "Under $100"
    case from100to300 = "$100–$300"
    case from300to600 = "$300–$600"
    case over600 = "$600+"

    func matches(buyIn: Int) -> Bool {
        switch self {
        case .any: return true
        case .under100: return buyIn < 100
        case .from100to300: return buyIn >= 100 && buyIn <= 300
        case .from300to600: return buyIn > 300 && buyIn <= 600
        case .over600: return buyIn > 600
        }
    }
}

// MARK: - TournamentBrowserView

struct TournamentBrowserView: View {
    @Environment(\.dismiss) private var dismiss

    let onSelect: (PokerAtlasScanResult) -> Void

    @State private var listings: [SharedTournamentListing] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var userLocation: CLLocation?
    @State private var selectedFilter: GameTypeFilter = .all

    // Filter state
    @State private var showFilters = false
    @State private var bountyOnly = false
    @State private var hasGuarantee = false
    @State private var allowsReentry = false
    @State private var selectedVenue: String? = nil
    @State private var buyInRange: BuyInRange = .any

    enum GameTypeFilter: String, CaseIterable {
        case all = "All"
        case nlh = "NLH"
        case plo = "PLO"
        case mixed = "Mixed"
    }

    // MARK: - Computed Properties

    private var filteredListings: [SharedTournamentListing] {
        var result = listings

        // Game type filter
        switch selectedFilter {
        case .all: break
        case .nlh: result = result.filter { $0.gameType == "NLH" }
        case .plo: result = result.filter { $0.gameType == "PLO" }
        case .mixed: result = result.filter { $0.gameType == "Mixed" }
        }

        // Bounty filter
        if bountyOnly {
            result = result.filter { $0.bountyAmount > 0 }
        }

        // Guarantee filter
        if hasGuarantee {
            result = result.filter { $0.guarantee > 0 }
        }

        // Re-entry filter
        if allowsReentry {
            result = result.filter { $0.reentryPolicy != "None" }
        }

        // Buy-in range filter
        if buyInRange != .any {
            result = result.filter { buyInRange.matches(buyIn: $0.buyIn) }
        }

        // Venue filter
        if let venue = selectedVenue {
            result = result.filter { $0.venueName == venue }
        }

        return result
    }

    private var availableVenues: [String] {
        Array(Set(listings.map { $0.venueName })).sorted()
    }

    private var activeFilterCount: Int {
        var count = 0
        if selectedFilter != .all { count += 1 }
        if bountyOnly { count += 1 }
        if hasGuarantee { count += 1 }
        if allowsReentry { count += 1 }
        if buyInRange != .any { count += 1 }
        if selectedVenue != nil { count += 1 }
        return count
    }

    private var hasAnyFilter: Bool {
        activeFilterCount > 0
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.backgroundPrimary.ignoresSafeArea()

                if isLoading {
                    loadingView
                } else if listings.isEmpty {
                    emptyView
                } else {
                    resultsView
                }
            }
            .navigationTitle("Nearby Events")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
            }
            .alert("Location Error", isPresented: $showingError) {
                Button("OK", role: .cancel) { dismiss() }
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
            .task {
                await loadNearbyEvents()
            }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.goldAccent)
                .scaleEffect(1.2)
            Text("Finding nearby events...")
                .font(PokerTypography.chatBody)
                .foregroundColor(.textSecondary)
        }
    }

    // MARK: - Empty State

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "map")
                .font(.system(size: 48))
                .foregroundColor(.textSecondary)
            Text("No Nearby Events")
                .font(.title3.weight(.semibold))
                .foregroundColor(.textPrimary)
            Text("Tournament listings are contributed by other players. Scan a Poker Atlas screenshot and toggle \"Share This Event\" to add yours!")
                .font(PokerTypography.chatBody)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: - Filtered Empty State

    private var filteredEmptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 48))
                .foregroundColor(.textSecondary)
            Text("No Matching Events")
                .font(.title3.weight(.semibold))
                .foregroundColor(.textPrimary)
            Text("Try adjusting your filters to see more events.")
                .font(PokerTypography.chatBody)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                clearAllFilters()
            } label: {
                Text("Clear Filters")
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(.backgroundPrimary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.goldAccent)
                    .clipShape(Capsule())
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Results

    private var resultsView: some View {
        VStack(spacing: 0) {
            filterSection
            resultCountBanner
            if filteredListings.isEmpty {
                Spacer()
                filteredEmptyView
                Spacer()
            } else {
                eventList
            }
        }
    }

    // MARK: - Filter Section

    private var filterSection: some View {
        VStack(spacing: 0) {
            // Game type chips + filter toggle
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(GameTypeFilter.allCases, id: \.self) { filter in
                            Button {
                                selectedFilter = filter
                            } label: {
                                Text(filter.rawValue)
                                    .font(PokerTypography.chipLabel)
                                    .foregroundColor(selectedFilter == filter ? .backgroundPrimary : .goldAccent)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(selectedFilter == filter ? Color.goldAccent : Color.goldAccent.opacity(0.15))
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(Color.goldAccent.opacity(0.3), lineWidth: 1))
                            }
                        }
                    }
                    .padding(.leading)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showFilters.toggle()
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(showFilters ? .backgroundPrimary : .goldAccent)
                            .padding(8)
                            .background(showFilters ? Color.goldAccent : Color.goldAccent.opacity(0.15))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.goldAccent.opacity(0.3), lineWidth: 1))

                        if activeFilterCount > 0 && !showFilters {
                            Text("\(activeFilterCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 16, height: 16)
                                .background(Color.chipRed)
                                .clipShape(Circle())
                                .offset(x: 4, y: -4)
                        }
                    }
                }
                .padding(.trailing)
                .padding(.leading, 8)
            }
            .padding(.vertical, 10)

            // Secondary toggle chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    toggleChip(
                        icon: "target",
                        label: "Bounty",
                        isActive: bountyOnly
                    ) {
                        bountyOnly.toggle()
                    }

                    toggleChip(
                        icon: "dollarsign.circle",
                        label: "GTD",
                        isActive: hasGuarantee
                    ) {
                        hasGuarantee.toggle()
                    }

                    toggleChip(
                        icon: "arrow.counterclockwise",
                        label: "Re-entry",
                        isActive: allowsReentry
                    ) {
                        allowsReentry.toggle()
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 10)
            }

            // Expanded filter section
            if showFilters {
                expandedFilterSection
            }
        }
    }

    private func toggleChip(icon: String, label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(PokerTypography.chipLabel)
            }
            .foregroundColor(isActive ? .backgroundPrimary : .goldAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isActive ? Color.goldAccent : Color.goldAccent.opacity(0.15))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.goldAccent.opacity(0.3), lineWidth: 1))
        }
    }

    private var expandedFilterSection: some View {
        VStack(spacing: 12) {
            // Buy-in range picker
            HStack {
                Text("Buy-in")
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(.textSecondary)
                Spacer()
                Menu {
                    ForEach(BuyInRange.allCases, id: \.self) { range in
                        Button {
                            buyInRange = range
                        } label: {
                            HStack {
                                Text(range.rawValue)
                                if buyInRange == range {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(buyInRange.rawValue)
                            .font(PokerTypography.chipLabel)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.goldAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.goldAccent.opacity(0.15))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.goldAccent.opacity(0.3), lineWidth: 1))
                }
            }

            // Venue picker (only when 2+ venues)
            if availableVenues.count >= 2 {
                HStack {
                    Text("Venue")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.textSecondary)
                    Spacer()
                    Menu {
                        Button {
                            selectedVenue = nil
                        } label: {
                            HStack {
                                Text("All Venues")
                                if selectedVenue == nil {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        ForEach(availableVenues, id: \.self) { venue in
                            Button {
                                selectedVenue = venue
                            } label: {
                                HStack {
                                    Text(venue)
                                    if selectedVenue == venue {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedVenue ?? "All Venues")
                                .font(PokerTypography.chipLabel)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.goldAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.goldAccent.opacity(0.15))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.goldAccent.opacity(0.3), lineWidth: 1))
                    }
                }
            }

            // Clear all filters
            if hasAnyFilter {
                Button {
                    clearAllFilters()
                } label: {
                    Text("Clear All Filters")
                        .font(PokerTypography.chipLabel)
                        .foregroundColor(.chipRed)
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Result Count Banner

    private var resultCountBanner: some View {
        HStack {
            let count = filteredListings.count
            let eventText = count == 1 ? "event" : "events"
            Text("\(count) \(eventText)")
                .font(PokerTypography.chatCaption)
                .foregroundColor(.textSecondary)

            if activeFilterCount > 0 {
                let filterText = activeFilterCount == 1 ? "filter" : "filters"
                Text("(\(activeFilterCount) \(filterText) active)")
                    .font(PokerTypography.chatCaption)
                    .foregroundColor(.goldAccent)
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.backgroundSecondary)
    }

    private var eventList: some View {
        List {
            ForEach(filteredListings) { listing in
                Button {
                    selectListing(listing)
                } label: {
                    eventRow(listing)
                }
                .listRowBackground(Color.cardSurface)
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Event Row

    private func eventRow(_ listing: SharedTournamentListing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title + game type badge + bounty badge
            HStack {
                Text(listing.tournamentName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)

                Spacer()

                if listing.bountyAmount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "target")
                            .font(.system(size: 9, weight: .medium))
                        Text("$\(listing.bountyAmount)")
                            .font(PokerTypography.chipLabel)
                    }
                    .foregroundColor(.chipRed)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.chipRed.opacity(0.15))
                    .clipShape(Capsule())
                }

                Text(listing.gameType)
                    .font(PokerTypography.chipLabel)
                    .foregroundColor(.goldAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.goldAccent.opacity(0.15))
                    .clipShape(Capsule())
            }

            // Venue + distance
            HStack {
                Image(systemName: "mappin")
                    .font(.caption2)
                    .foregroundColor(.textSecondary)
                Text(listing.venueName)
                    .font(.caption)
                    .foregroundColor(.textSecondary)

                if let loc = userLocation {
                    Text("·")
                        .foregroundColor(.textSecondary)
                    Text(listing.distanceFormatted(from: loc))
                        .font(.caption)
                        .foregroundColor(.goldAccent)
                }
            }

            // Details row
            HStack(spacing: 12) {
                if listing.buyIn > 0 {
                    detailLabel("Buy-in", value: "$\(listing.buyIn)")
                }
                if listing.guarantee > 0 {
                    detailLabel("GTD", value: "$\(formatNumber(listing.guarantee))")
                }
                if listing.startingChips > 0 {
                    detailLabel("Chips", value: formatNumber(listing.startingChips))
                }
                if listing.reentryPolicy != "None" {
                    detailLabel("Re-entry", value: listing.reentryPolicy)
                }
            }

            // Date/time + blind levels
            HStack {
                Image(systemName: "calendar")
                    .font(.caption2)
                    .foregroundColor(.textSecondary)
                Text(formatEventDate(listing.eventDate))
                    .font(.caption)
                    .foregroundColor(.textSecondary)

                Spacer()

                if !listing.blindLevels.isEmpty {
                    Text("\(listing.blindLevels.count) blind levels")
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func detailLabel(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.textSecondary)
            Text(value)
                .font(PokerTypography.chipLabel)
                .foregroundColor(.textPrimary)
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1000 {
            let k = Double(n) / 1000.0
            if k == Double(Int(k)) {
                return "\(Int(k))K"
            }
            return String(format: "%.1fK", k)
        }
        return "\(n)"
    }

    private func formatEventDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }

    private func selectListing(_ listing: SharedTournamentListing) {
        let scanResult = listing.toScanResult()
        onSelect(scanResult)
        dismiss()
    }

    private func clearAllFilters() {
        selectedFilter = .all
        bountyOnly = false
        hasGuarantee = false
        allowsReentry = false
        selectedVenue = nil
        buyInRange = .any
    }

    private func loadNearbyEvents() async {
        do {
            let location = try await LocationManager.shared.requestLocationOnce()
            userLocation = location

            let results = try await CloudKitService.shared.fetchNearby(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
            listings = results
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}
