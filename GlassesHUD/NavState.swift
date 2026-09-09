import CoreLocation
import CoreMotion
import Foundation

/// Fast navigation state: GPS fixes arrive once a second, so between them the heading is carried by
/// the phone's gyroscope (50 Hz) and the position is dead-reckoned along the heading at the last speed.
/// The gyro's rotation rate is taken about the gravity axis, so it does not matter how the phone is mounted.
@MainActor
final class NavState {

    static let shared = NavState()

    /// Fused heading, degrees true north, nil until the first usable source.
    private(set) var heading: Double?
    private(set) var headingSource = "—"

    private var lastFix: CLLocation?
    private var headingAtFix: Double?
    private let motion = CMMotionManager()
    private var lastMotionTime: TimeInterval?

    private init() {}

    // MARK: - Inputs

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 50.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            self.ingest(motion: data)
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        lastMotionTime = nil
    }

    private func ingest(motion data: CMDeviceMotion) {
        defer { lastMotionTime = data.timestamp }
        guard let last = lastMotionTime, heading != nil else { return }
        let dt = data.timestamp - last
        guard dt > 0, dt < 0.5 else { return }

        // Angular velocity about the "down" axis = clockwise turn rate seen from above.
        let g = data.gravity
        let norm = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        guard norm > 0.5 else { return }
        let r = data.rotationRate
        let downRate = (r.x * g.x + r.y * g.y + r.z * g.z) / norm     // rad/s, clockwise positive
        heading = Self.wrap((heading ?? 0) + downRate * 180 / .pi * dt)
    }

    /// New GPS fix. Corrects the gyro heading with the GPS course while moving.
    func ingest(location: CLLocation, compass: CLHeading?, source: HeadingSource) {
        lastFix = location
        let course: Double? = (location.course >= 0 && location.speed >= 1.5) ? location.course : nil
        let compassHeading: Double? = (compass?.trueHeading ?? -1) >= 0 ? compass?.trueHeading : nil

        let reference: Double?
        switch source {
        case .gps: reference = course
        case .compass: reference = compassHeading ?? course
        case .auto: reference = course ?? (heading == nil ? compassHeading : nil)
        }

        if let reference {
            if let current = heading {
                let error = Self.wrap(reference - current + 180) - 180   // -180...180
                heading = Self.wrap(current + (abs(error) > 45 ? error : error * 0.35))
            } else {
                heading = reference
            }
            headingSource = course != nil && reference == course ? "GPS+gyro" : "compass+gyro"
        }
        headingAtFix = heading
    }

    // MARK: - Outputs

    /// Position at `date`, dead-reckoned from the last fix along the heading (at most 2 s ahead).
    func coordinate(at date: Date) -> CLLocationCoordinate2D? {
        guard let fix = lastFix else { return nil }
        let age = min(max(date.timeIntervalSince(fix.timestamp), 0), 2.0)
        guard fix.speed > 0.5, let heading else { return fix.coordinate }
        let distance = fix.speed * age
        let h = heading * .pi / 180
        let c = fix.coordinate
        let dLat = distance * cos(h) / 111_320
        let dLon = distance * sin(h) / (111_320 * cos(c.latitude * .pi / 180))
        return CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLon)
    }

    private static func wrap(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }
}
