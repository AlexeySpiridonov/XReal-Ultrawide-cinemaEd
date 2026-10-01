import CoreLocation
import Foundation

/// One road from OpenStreetMap: class, name and its polyline.
struct Road {
    enum Kind: Int, Comparable {
        case service, residential, tertiary, secondary, primary, motorway
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        init(highway: String) {
            switch highway {
            case "motorway", "trunk", "motorway_link", "trunk_link": self = .motorway
            case "primary", "primary_link": self = .primary
            case "secondary", "secondary_link": self = .secondary
            case "tertiary", "tertiary_link": self = .tertiary
            case "residential", "unclassified": self = .residential
            default: self = .service
            }
        }
    }

    let kind: Kind
    let name: String?
    let points: [CLLocationCoordinate2D]
}

/// Loads the roads around the current position from OpenStreetMap (Overpass API) and keeps them
/// while you stay within the loaded area. Refetches once you move ~400 m from the fetch centre.
@MainActor
final class RoadDataService: ObservableObject {

    static let shared = RoadDataService()

    @Published private(set) var roads: [Road] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    /// Half-size of the loaded square, degrees (~1.1 km).
    private let halfSpan = 0.010
    private let refetchDistance: CLLocationDistance = 400
    private var fetchCenter: CLLocation?
    private var task: Task<Void, Never>?

    private init() {}

    func update(for location: CLLocation) {
        if let fetchCenter, location.distance(from: fetchCenter) < refetchDistance { return }
        guard task == nil else { return }
        fetchCenter = location
        task = Task { [weak self] in
            await self?.fetch(around: location.coordinate)
            self?.task = nil
        }
    }

    private func fetch(around c: CLLocationCoordinate2D) async {
        isLoading = true
        defer { isLoading = false }

        let bbox = "\(c.latitude - halfSpan),\(c.longitude - halfSpan),\(c.latitude + halfSpan),\(c.longitude + halfSpan)"
        let classes = "motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|service|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link"
        let query = "[out:json][timeout:15];way[\"highway\"~\"^(\(classes))$\"](\(bbox));out geom;"

        var request = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        request.httpMethod = "POST"
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)".data(using: .utf8)
        request.setValue("GlassesHUD/1.0 (XReal HUD prototype)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            roads = try Self.parse(data)
            lastError = nil
            print("[Roads] Loaded \(roads.count) roads around \(c.latitude), \(c.longitude)")
        } catch {
            lastError = error.localizedDescription
            print("[Roads] \(error.localizedDescription)")
            fetchCenter = nil  // retry on the next update
        }
    }

    private static func parse(_ data: Data) throws -> [Road] {
        struct Response: Decodable {
            struct Element: Decodable {
                struct Point: Decodable { let lat: Double; let lon: Double }
                let type: String
                let tags: [String: String]?
                let geometry: [Point]?
            }
            let elements: [Element]
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.elements.compactMap { element in
            guard element.type == "way", let geometry = element.geometry, geometry.count >= 2,
                  let highway = element.tags?["highway"] else { return nil }
            return Road(kind: Road.Kind(highway: highway),
                        name: element.tags?["name"],
                        points: geometry.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
        }
        .sorted { $0.kind < $1.kind }   // draw minor roads first, major roads on top
    }
}
