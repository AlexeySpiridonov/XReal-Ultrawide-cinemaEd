import CoreLocation
import SwiftUI

/// What the glasses show. Black is transparent in the glasses, so everything sits on black.
/// Left: the numbers in one column. Right: the road you are on, heading-up.
struct HUDView: View {
    @ObservedObject private var model = HUDModel.shared
    @ObservedObject private var route = RouteService.shared
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let hudColor = Color(red: 0.55, green: 1.0, blue: 0.75)
    private let dimColor = Color(red: 0.55, green: 1.0, blue: 0.75).opacity(0.6)

    var body: some View {
        GeometryReader { geometry in
            let unit = min(geometry.size.width, geometry.size.height) / 20 * model.hudScale
            let margin = unit * 0.8

            ZStack {
                Color.black

                HStack(alignment: .top, spacing: margin) {
                    // Left column: all the readouts
                    VStack(alignment: .leading, spacing: unit * 0.9) {
                        if model.showSpeed { speedBlock(unit: unit) }
                        if model.showHeading { headingBlock(unit: unit) }
                        if model.showAltitude { altitudeBlock(unit: unit) }
                        if model.showTarget, model.target != nil { targetBlock(unit: unit) }
                        if model.showCoordinates { coordinatesBlock(unit: unit) }
                        Spacer(minLength: 0)
                        if model.showClock { clockBlock(unit: unit) }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)

                    Spacer(minLength: 0)

                    // Right: the road you are on
                    if model.showMap {
                        roadBlock(unit: unit)
                            .frame(width: geometry.size.width * 0.46 * model.mapSize)
                            .frame(height: (geometry.size.height - margin * 2) * model.mapSize, alignment: .top)
                    }
                }
                .padding(margin)

                if model.fixIsStale {
                    Text(model.authorization == .denied ? "LOCATION ACCESS DENIED" : "NO GPS FIX")
                        .font(.system(size: unit * 0.8, weight: .semibold, design: .rounded))
                        .foregroundStyle(.orange)
                        .padding(unit * 0.3)
                        .overlay(RoundedRectangle(cornerRadius: unit * 0.2).stroke(.orange, lineWidth: unit * 0.05))
                }
            }
            .foregroundStyle(hudColor)
            .monospacedDigit()
        }
        .ignoresSafeArea()
        .onReceive(tick) { now = $0 }
    }

    // MARK: - Readouts

    private func speedBlock(unit: CGFloat) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: unit * 0.3) {
            let value = model.speed.map { model.speedUnit.convert($0) }
            Text(value.map { String(format: "%.0f", $0) } ?? "--")
                .font(.system(size: unit * 3.2, weight: .bold, design: .rounded))
            Text(model.speedUnit.label)
                .font(.system(size: unit * 0.9, weight: .medium, design: .rounded))
                .foregroundStyle(dimColor)
        }
    }

    private func headingBlock(unit: CGFloat) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: unit * 0.3) {
            if let heading = model.heading {
                Text(String(format: "%03.0f°", heading))
                    .font(.system(size: unit * 2.0, weight: .bold, design: .rounded))
                Text(Self.cardinal(heading))
                    .font(.system(size: unit * 1.0, weight: .semibold, design: .rounded))
                    .foregroundStyle(dimColor)
            } else {
                Text("---°")
                    .font(.system(size: unit * 2.0, weight: .bold, design: .rounded))
            }
        }
    }

    private func altitudeBlock(unit: CGFloat) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: unit * 0.3) {
            Text(model.location.map { String(format: "%.0f m", $0.altitude) } ?? "-- m")
                .font(.system(size: unit * 1.6, weight: .semibold, design: .rounded))
            Text("ALT")
                .font(.system(size: unit * 0.7, weight: .medium, design: .rounded))
                .foregroundStyle(dimColor)
        }
    }

    private func targetBlock(unit: CGFloat) -> some View {
        HStack(alignment: .center, spacing: unit * 0.5) {
            Image(systemName: "location.north.fill")
                .font(.system(size: unit * 2.0, weight: .bold))
                .rotationEffect(.degrees(model.relativeBearing ?? 0))
                .opacity(model.relativeBearing == nil ? 0.3 : 1)
            VStack(alignment: .leading, spacing: 0) {
                Text((route.routeDistance ?? model.distanceToTarget).map(Self.formatDistance) ?? "--")
                    .font(.system(size: unit * 1.6, weight: .bold, design: .rounded))
                HStack(spacing: unit * 0.3) {
                    Text(route.routeDistance != nil ? "ROUTE" : "TARGET")
                    if let time = route.expectedTravelTime {
                        Text("\(Int(time / 60)) min")
                    }
                }
                .font(.system(size: unit * 0.7, weight: .medium, design: .rounded))
                .foregroundStyle(dimColor)
            }
        }
    }

    private func coordinatesBlock(unit: CGFloat) -> some View {
        Group {
            if let c = model.location?.coordinate {
                Text(String(format: "%.5f  %.5f", c.latitude, c.longitude))
                    .font(.system(size: unit * 0.8, weight: .medium, design: .rounded))
                    .foregroundStyle(dimColor)
            }
        }
    }

    private func clockBlock(unit: CGFloat) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: unit * 0.4) {
            Text(now, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .font(.system(size: unit * 1.4, weight: .semibold, design: .rounded))
            if let accuracy = model.location?.horizontalAccuracy, accuracy >= 0 {
                Text("GPS ±\(Int(accuracy)) m")
                    .font(.system(size: unit * 0.7, weight: .medium, design: .rounded))
                    .foregroundStyle(dimColor)
            }
        }
    }

    // MARK: - Road map

    private func roadBlock(unit: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: unit * 0.3) {
            Text(model.roadName ?? "—")
                .font(.system(size: unit * 1.3, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            RoadCanvasView(model: model, unit: unit, color: hudColor)
                .clipShape(RoundedRectangle(cornerRadius: unit * 0.4))
                .overlay(RoundedRectangle(cornerRadius: unit * 0.4).stroke(dimColor.opacity(0.4), lineWidth: unit * 0.04))
        }
    }

    // MARK: - Formatting

    static func cardinal(_ degrees: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((degrees / 45).rounded()) % 8
        return names[index]
    }

    static func formatDistance(_ meters: CLLocationDistance) -> String {
        meters < 1000 ? String(format: "%.0f m", meters) : String(format: "%.1f km", meters / 1000)
    }
}

/// Roads only, on black: OpenStreetMap road lines around you, heading-up, you near the bottom.
private struct RoadCanvasView: View {
    @ObservedObject var model: HUDModel
    @ObservedObject private var roadData = RoadDataService.shared
    @ObservedObject private var route = RouteService.shared
    let unit: CGFloat
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard let location = model.location else { return }
            let heading = (model.heading ?? 0) * .pi / 180
            let origin = location.coordinate
            let metresPerDegreeLat = 111_320.0
            let metresPerDegreeLon = 111_320.0 * cos(origin.latitude * .pi / 180)

            // You are 80% down the map; `mapAhead` metres fit above you.
            let scale = size.height / CGFloat(model.mapAhead * 1.25)
            let you = CGPoint(x: size.width / 2, y: size.height * 0.8)
            let sinH = sin(heading), cosH = cos(heading)

            func project(_ c: CLLocationCoordinate2D) -> CGPoint {
                let east = (c.longitude - origin.longitude) * metresPerDegreeLon
                let north = (c.latitude - origin.latitude) * metresPerDegreeLat
                let forward = east * sinH + north * cosH
                let right = east * cosH - north * sinH
                return CGPoint(x: you.x + CGFloat(right) * scale, y: you.y - CGFloat(forward) * scale)
            }

            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -size.width, dy: -size.height)
            for road in roadData.roads {
                var path = Path()
                var visible = false
                for (i, c) in road.points.enumerated() {
                    let p = project(c)
                    if bounds.contains(p) { visible = true }
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                guard visible else { continue }

                let isCurrent = road.name != nil && road.name == model.roadName
                let width: CGFloat
                let opacity: Double
                switch road.kind {
                case .motorway: width = unit * 0.40; opacity = 1.0
                case .primary: width = unit * 0.32; opacity = 0.95
                case .secondary: width = unit * 0.26; opacity = 0.85
                case .tertiary: width = unit * 0.20; opacity = 0.75
                case .residential: width = unit * 0.14; opacity = 0.6
                case .service: width = unit * 0.08; opacity = 0.4
                }
                context.stroke(path, with: .color(color.opacity(isCurrent ? 1.0 : opacity)),
                               style: StrokeStyle(lineWidth: isCurrent ? width * 1.4 : width, lineCap: .round, lineJoin: .round))
            }

            // Route to the target: dashed, in the target colour
            if route.polyline.count >= 2 {
                var path = Path()
                for (i, c) in route.polyline.enumerated() {
                    let p = project(c)
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                context.stroke(path, with: .color(.orange.opacity(0.9)),
                               style: StrokeStyle(lineWidth: unit * 0.22, lineCap: .round, lineJoin: .round,
                                                  dash: [unit * 0.55, unit * 0.45]))
            }

            // You: a small arrow pointing up
            var arrow = Path()
            let a = unit * 0.45
            arrow.move(to: CGPoint(x: you.x, y: you.y - a))
            arrow.addLine(to: CGPoint(x: you.x + a * 0.6, y: you.y + a * 0.7))
            arrow.addLine(to: CGPoint(x: you.x, y: you.y + a * 0.3))
            arrow.addLine(to: CGPoint(x: you.x - a * 0.6, y: you.y + a * 0.7))
            arrow.closeSubpath()
            context.fill(arrow, with: .color(.orange))
        }
        .overlay(alignment: .bottomLeading) {
            if roadData.roads.isEmpty {
                Text(roadData.isLoading ? "loading roads…" : (roadData.lastError ?? "no road data"))
                    .font(.system(size: unit * 0.6, design: .rounded))
                    .foregroundStyle(color.opacity(0.6))
                    .padding(unit * 0.3)
            }
        }
        .onChange(of: model.location) { _, location in
            guard let location else { return }
            roadData.update(for: location)
            route.update(location: location, target: model.target)
        }
        .onChange(of: model.target) { _, target in
            if let location = model.location { route.update(location: location, target: target) }
        }
        .onAppear {
            guard let location = model.location else { return }
            roadData.update(for: location)
            route.update(location: location, target: model.target)
        }
    }
}

#Preview {
    HUDView().frame(width: 960, height: 540)
}
