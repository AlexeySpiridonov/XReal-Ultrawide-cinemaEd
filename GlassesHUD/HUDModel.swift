import CoreLocation
import Foundation
import SwiftUI

enum SpeedUnit: String, CaseIterable, Identifiable {
    case kmh, ms, mph
    var id: String { rawValue }
    var label: String {
        switch self {
        case .kmh: return "km/h"
        case .ms: return "m/s"
        case .mph: return "mph"
        }
    }
    func convert(_ metersPerSecond: Double) -> Double {
        switch self {
        case .kmh: return metersPerSecond * 3.6
        case .ms: return metersPerSecond
        case .mph: return metersPerSecond * 2.23694
        }
    }
}

enum HeadingSource: String, CaseIterable, Identifiable {
    case auto, compass, gps
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto (GPS when moving)"
        case .compass: return "Compass"
        case .gps: return "GPS course"
        }
    }
}

/// Shared state between the phone UI and the glasses HUD.
@MainActor
final class HUDModel: ObservableObject {

    static let shared = HUDModel()

    // Live data
    @Published var location: CLLocation?
    @Published var compassHeading: CLHeading?
    @Published var authorization: CLAuthorizationStatus = .notDetermined
    @Published var glassesConnected = false
    /// Name of the road at the current position (reverse geocoded, updated every ~100 m).
    @Published var roadName: String?

    // Settings (persisted)
    @AppStorage("showSpeed") var showSpeed = true
    @AppStorage("showHeading") var showHeading = true
    @AppStorage("showAltitude") var showAltitude = true
    @AppStorage("showTarget") var showTarget = true
    @AppStorage("showCoordinates") var showCoordinates = false
    @AppStorage("showClock") var showClock = true
    @AppStorage("showMap") var showMap = true
    @AppStorage("mapAhead") var mapAhead: Double = 150   // metres of road visible ahead of you
    @AppStorage("dimPhoneScreen") var dimPhoneScreen = true
    @AppStorage("speedUnit") var speedUnit: SpeedUnit = .kmh
    @AppStorage("headingSource") var headingSource: HeadingSource = .auto
    @AppStorage("hudScale") var hudScale: Double = 1.0
    @AppStorage("targetLat") private var targetLat: Double = .nan
    @AppStorage("targetLon") private var targetLon: Double = .nan

    private init() {}

    var target: CLLocationCoordinate2D? {
        get { targetLat.isNaN ? nil : CLLocationCoordinate2D(latitude: targetLat, longitude: targetLon) }
        set {
            objectWillChange.send()
            targetLat = newValue?.latitude ?? .nan
            targetLon = newValue?.longitude ?? .nan
        }
    }

    // MARK: - Derived values

    /// Speed in m/s, nil when unknown.
    var speed: Double? {
        guard let location, location.speed >= 0 else { return nil }
        return location.speed
    }

    var isMoving: Bool { (speed ?? 0) > 1.0 }

    /// Heading in degrees true north, nil when unknown.
    var heading: Double? {
        let gps: Double? = (location?.course ?? -1) >= 0 ? location?.course : nil
        let compass: Double? = (compassHeading?.trueHeading ?? -1) >= 0 ? compassHeading?.trueHeading : nil
        switch headingSource {
        case .gps: return gps
        case .compass: return compass ?? gps
        case .auto: return isMoving ? (gps ?? compass) : (compass ?? gps)
        }
    }

    var distanceToTarget: CLLocationDistance? {
        guard let location, let target else { return nil }
        return location.distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
    }

    /// Bearing to the target in degrees true north.
    var bearingToTarget: Double? {
        guard let location, let target else { return nil }
        let from = location.coordinate
        let lat1 = from.latitude * .pi / 180, lat2 = target.latitude * .pi / 180
        let dLon = (target.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Where the target is relative to where you are facing, degrees (-180...180), nil when unknown.
    var relativeBearing: Double? {
        guard let bearingToTarget, let heading else { return nil }
        var rel = bearingToTarget - heading
        if rel > 180 { rel -= 360 }
        if rel < -180 { rel += 360 }
        return rel
    }

    /// GPS fix older than this counts as lost.
    var fixIsStale: Bool {
        guard let location else { return true }
        return Date().timeIntervalSince(location.timestamp) > 10
    }
}

extension CLLocationCoordinate2D: @retroactive Equatable {
    public static func == (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
}
