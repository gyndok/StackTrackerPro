import SwiftUI
import CoreLocation

struct TournamentBrowserView: View {
    @Environment(\.dismiss) private var dismiss

    let onSelect: (PokerAtlasScanResult) -> Void

    @State private var listings: [SharedTournamentListing] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var userLocation: CLLocation?
    @State private var selectedFilter: GameTypeFilter = .all

    enum GameTypeFilter: String, CaseIterable {
        case all = "All"
        case nlh = "NLH"
        case plo = "PLO"
        case mixed = "Mixed"
    }

    private var filteredListings: [SharedTournamentListing] {
        switch selectedFilter {
        case .all: return listings
        case .nlh: return listings.filter { $0.gameType == "NLH" }
        case .plo: return listings.filter { $0.gameType == "PLO" }
        case .mixed: return listings.filter { $0.gameType == "Mixed" }
        }
    }

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

    // MARK: - Results

    private var resultsView: some View {
        VStack(spacing: 0) {
            filterChips
            eventList
        }
    }

    private var filterChips: some View {
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
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
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
            // Title + game type badge
            HStack {
                Text(listing.tournamentName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)

                Spacer()

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
