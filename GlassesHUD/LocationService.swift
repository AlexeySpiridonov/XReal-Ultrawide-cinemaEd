import CoreLocation
import Foundation

/// Feeds CoreLocation updates into HUDModel. Keeps updating in the background so the HUD
/// stays live when the phone is in a pocket (requires the "location" background mode).
final class LocationService: NSObject, CLLocationManagerDelegate {

    static let shared = LocationService()

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastGeocodedLocation: CLLocation?
    private var lastGeocodeTime = Date.distantPast

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.headingFilter = 2
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        default:
            break
        }
    }

    private func beginUpdates() {
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in HUDModel.shared.authorization = status }
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            beginUpdates()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in HUDModel.shared.location = last }
        updateRoadName(for: last)
    }

    /// Reverse geocodes at most every 100 m / 10 s (Apple rate-limits the geocoder).
    private func updateRoadName(for location: CLLocation) {
        let moved = lastGeocodedLocation.map { location.distance(from: $0) } ?? .infinity
        guard moved > 100, Date().timeIntervalSince(lastGeocodeTime) > 10, !geocoder.isGeocoding else { return }
        lastGeocodedLocation = location
        lastGeocodeTime = Date()
        geocoder.reverseGeocodeLocation(location) { placemarks, error in
            guard let placemark = placemarks?.first else {
                if let error { print("[Geocoder] \(error.localizedDescription)") }
                return
            }
            // Only a street name; a nearby landmark would be misleading. Keep the last street otherwise.
            guard let street = placemark.thoroughfare else { return }
            Task { @MainActor in HUDModel.shared.roadName = street }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in HUDModel.shared.compassHeading = newHeading }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[Location] \(error.localizedDescription)")
    }
}
