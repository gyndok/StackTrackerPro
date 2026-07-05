import CoreLocation
import MapKit

@MainActor
final class LocationManager: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = LocationManager()

    private let manager = CLLocationManager()
    private var cachedLocation: CLLocation?
    private var cacheTimestamp: Date?
    private let cacheDuration: TimeInterval = 300 // 5 minutes

    // Multiple callers can await a fix or an authorization change at once;
    // every continuation is resumed (exactly once) by the delegate callbacks,
    // so none is ever dropped unresumed.
    private var locationContinuations: [CheckedContinuation<CLLocation, any Error>] = []
    private var authorizationContinuations: [CheckedContinuation<CLAuthorizationStatus, Never>] = []

    private override init() {
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.delegate = self
    }

    func requestLocationOnce() async throws -> CLLocation {
        // Return cached if fresh
        if let cached = cachedLocation, let ts = cacheTimestamp,
           Date().timeIntervalSince(ts) < cacheDuration {
            return cached
        }

        var status = manager.authorizationStatus
        if status == .notDetermined {
            // Await the real authorization change instead of sleeping —
            // first-time users may take arbitrarily long to answer the prompt.
            status = await requestAuthorization()
        }

        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            throw LocationError.permissionDenied
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.locationContinuations.append(continuation)
            // Only the first waiter kicks off a request; the delegate
            // callback resumes everyone.
            if self.locationContinuations.count == 1 {
                self.manager.requestLocation()
            }
        }
    }

    private func requestAuthorization() async -> CLAuthorizationStatus {
        await withCheckedContinuation { continuation in
            self.authorizationContinuations.append(continuation)
            if self.authorizationContinuations.count == 1 {
                self.manager.requestWhenInUseAuthorization()
            }
        }
    }

    func geocodeVenue(name: String, city: String, state: String) async -> CLLocation? {
        // Build the query from non-empty components only. The old code sent
        // "Name, , " (and fell back to ", ") when city/state were blank —
        // queries that can resolve to arbitrary places near the user.
        let components = [name, city, state]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }

        if let location = await geocodeAddress(components.joined(separator: ", ")) {
            return location
        }

        // Fall back to city/state only when we actually have them — a city-
        // center pin is fine for the 50-mile nearby browser.
        let cityComponents = [city, state]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !cityComponents.isEmpty, cityComponents.count < components.count else { return nil }
        return await geocodeAddress(cityComponents.joined(separator: ", "))
    }

    private func geocodeAddress(_ address: String) async -> CLLocation? {
        let searchRequest = MKLocalSearch.Request()
        searchRequest.naturalLanguageQuery = address
        let search = MKLocalSearch(request: searchRequest)
        guard let response = try? await search.start() else { return nil }
        guard let item = response.mapItems.first else { return nil }
        let coord = item.location.coordinate
        return CLLocation(latitude: coord.latitude, longitude: coord.longitude)
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else { return }
        Task { @MainActor in
            self.cachedLocation = location
            self.cacheTimestamp = Date()
            let waiters = self.locationContinuations
            self.locationContinuations = []
            for waiter in waiters {
                waiter.resume(returning: location)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor in
            let waiters = self.locationContinuations
            self.locationContinuations = []
            for waiter in waiters {
                waiter.resume(throwing: LocationError.locationUnavailable)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            // .notDetermined fires when the delegate is first attached and
            // while the permission prompt is still on screen — keep waiting.
            guard status != .notDetermined else { return }
            let waiters = self.authorizationContinuations
            self.authorizationContinuations = []
            for waiter in waiters {
                waiter.resume(returning: status)
            }
        }
    }
}

// MARK: - Error

enum LocationError: LocalizedError {
    case permissionDenied
    case locationUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Location permission is required to find nearby tournaments."
        case .locationUnavailable:
            return "Unable to determine your location. Please try again."
        }
    }
}
