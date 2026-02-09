import CoreLocation
import MapKit

@MainActor
final class LocationManager: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = LocationManager()

    private let manager = CLLocationManager()
    private var cachedLocation: CLLocation?
    private var cacheTimestamp: Date?
    private let cacheDuration: TimeInterval = 300 // 5 minutes

    private var locationContinuation: CheckedContinuation<CLLocation, any Error>?

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

        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            // Wait briefly for authorization
            try await Task.sleep(for: .milliseconds(500))
        }

        let currentStatus = manager.authorizationStatus
        guard currentStatus == .authorizedWhenInUse || currentStatus == .authorizedAlways else {
            throw LocationError.permissionDenied
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.locationContinuation = continuation
            self.manager.requestLocation()
        }
    }

    func geocodeVenue(name: String, city: String, state: String) async -> CLLocation? {
        // Try full venue name + city + state first
        let fullAddress = "\(name), \(city), \(state)"
        if let location = await geocodeAddress(fullAddress) {
            return location
        }

        // Fall back to city + state only
        let fallback = "\(city), \(state)"
        return await geocodeAddress(fallback)
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
            self.locationContinuation?.resume(returning: location)
            self.locationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor in
            self.locationContinuation?.resume(throwing: LocationError.locationUnavailable)
            self.locationContinuation = nil
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
