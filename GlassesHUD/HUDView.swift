import CoreLocation
import SwiftUI

/// What the glasses show. Black is transparent in the glasses, so everything sits on black.
struct HUDView: View {
    @ObservedObject private var model = HUDModel.shared
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

                // Top row: speed, heading, clock
                VStack {
                    HStack(alignment: .top) {
                        if model.showSpeed { speedBlock(unit: unit) }
                        Spacer()
                        if model.showHeading { headingBlock(unit: unit) }
                        Spacer()
                        if model.showClock { clockBlock(unit: unit) }
                    }
                    Spacer()
                    HStack(alignment: .bottom) {
                        if model.showAltitude { altitudeBlock(unit: unit) }
                        Spacer()
                        if model.showCoordinates { coordinatesBlock(unit: unit) }
                        Spacer()
                        if model.showTarget { targetBlock(unit: unit) }
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

    // MARK: - Blocks

    private func speedBlock(unit: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            let value = model.speed.map { model.speedUnit.convert($0) }
            Text(value.map { String(format: "%.0f", $0) } ?? "--")
                .font(.system(size: unit * 3.2, weight: .bold, design: .rounded))
            Text(model.speedUnit.label)
                .font(.system(size: unit * 0.9, weight: .medium, design: .rounded))
                .foregroundStyle(dimColor)
        }
    }

    private func headingBlock(unit: CGFloat) -> some View {
        VStack(spacing: unit * 0.1) {
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

    private func clockBlock(unit: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(now, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .font(.system(size: unit * 1.6, weight: .semibold, design: .rounded))
            if let accuracy = model.location?.horizontalAccuracy, accuracy >= 0 {
                Text("GPS ±\(Int(accuracy)) m")
                    .font(.system(size: unit * 0.7, weight: .medium, design: .rounded))
                    .foregroundStyle(dimColor)
            }
        }
    }

    private func altitudeBlock(unit: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.location.map { String(format: "%.0f m", $0.altitude) } ?? "-- m")
                .font(.system(size: unit * 1.6, weight: .semibold, design: .rounded))
            Text("ALT")
                .font(.system(size: unit * 0.7, weight: .medium, design: .rounded))
                .foregroundStyle(dimColor)
        }
    }

    private func coordinatesBlock(unit: CGFloat) -> some View {
        VStack(spacing: 0) {
            if let c = model.location?.coordinate {
                Text(String(format: "%.5f  %.5f", c.latitude, c.longitude))
                    .font(.system(size: unit * 0.8, weight: .medium, design: .rounded))
                    .foregroundStyle(dimColor)
            }
        }
    }

    private func targetBlock(unit: CGFloat) -> some View {
        HStack(alignment: .center, spacing: unit * 0.5) {
            if model.target != nil {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(model.distanceToTarget.map(Self.formatDistance) ?? "--")
                        .font(.system(size: unit * 1.8, weight: .bold, design: .rounded))
                    Text("TARGET")
                        .font(.system(size: unit * 0.7, weight: .medium, design: .rounded))
                        .foregroundStyle(dimColor)
                }
                Image(systemName: "location.north.fill")
                    .font(.system(size: unit * 2.4, weight: .bold))
                    .rotationEffect(.degrees(model.relativeBearing ?? 0))
                    .opacity(model.relativeBearing == nil ? 0.3 : 1)
            }
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

#Preview {
    HUDView().frame(width: 960, height: 540)
}
