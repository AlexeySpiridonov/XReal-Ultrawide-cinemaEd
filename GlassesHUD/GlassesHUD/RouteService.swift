import CoreLocation
import Foundation
import MapKit

/// Driving route from the current position to the target (MapKit directions).
/// Recomputed when the target changes, when you stray more than `offRouteDistance` from it,
/// or periodically while moving.
@MainActor
final class RouteService: ObservableObject {

    static let shared = RouteService()

    @Published private(set) var polyline: [CLLocationCoordinate2D] = []
    @Published private(set) var routeDistance: CLLocationDistance?
    @Published private(set) var expectedTravelTime: TimeInterval?
    @Published private(set) var isCalculating = false

    private let offRouteDistance: CLLocationDistance = 60
    private let refreshInterval: TimeInterval = 120
    private var routedTarget: CLLocationCoordinate2D?
    private var routedFrom: CLLocation?
    private var lastCalculation = Date.distantPast
    private var task: Task<Void, Never>?

    private init() {}

    func update(location: CLLocation, target: CLLocationCoordinate2D?) {
        guard let target else {
            clear()
            return
        }
        let targetChanged = routedTarget.map { $0 != target } ?? true
        let stale = Date().timeIntervalSince(lastCalculation) > refreshInterval
            && (routedFrom.map { location.distance(from: $0) > 200 } ?? true)
        let offRoute = !polyline.isEmpty && distance(from: location.coordinate, toPolyline: polyline) > offRouteDistance
        guard targetChanged || stale || offRoute, task == nil else { return }

        routedTarget = target
        routedFrom = location
        lastCalculation = Date()
        task = Task { [weak self] in
            await self?.calculate(from: location.coordinate, to: target)
            self?.task = nil
        }
    }

    func clear() {
        polyline = []
        routeDistance = nil
        expectedTravelTime = nil
        routedTarget = nil
        routedFrom = nil
    }

    private func calculate(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async {
        isCalculating = true
        defer { isCalculating = false }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .automobile
        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else { return }
            let count = route.polyline.pointCount
            var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: count)
            route.polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: count))
            polyline = coordinates
            routeDistance = route.distance
            expectedTravelTime = route.expectedTravelTime
            print("[Route] \(Int(route.distance)) m, \(Int(route.expectedTravelTime / 60)) min, \(count) points")
        } catch {
            print("[Route] \(error.localizedDescription)")
            lastCalculation = Date().addingTimeInterval(-refreshInterval + 20)  // retry in ~20 s
        }
    }

    /// Shortest distance in metres from a point to a polyline (equirectangular approximation).
    private func distance(from c: CLLocationCoordinate2D, toPolyline line: [CLLocationCoordinate2D]) -> CLLocationDistance {
        guard line.count >= 2 else { return .infinity }
        let kLat = 111_320.0
        let kLon = 111_320.0 * cos(c.latitude * .pi / 180)
        func xy(_ p: CLLocationCoordinate2D) -> (Double, Double) {
            ((p.longitude - c.longitude) * kLon, (p.latitude - c.latitude) * kLat)
        }
        var best = Double.infinity
        for i in 1..<line.count {
            let (ax, ay) = xy(line[i - 1])
            let (bx, by) = xy(line[i])
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, (-ax * dx - ay * dy) / len2)) : 0
            let px = ax + t * dx, py = ay + t * dy
            best = min(best, (px * px + py * py).squareRoot())
        }
        return best
    }
}
