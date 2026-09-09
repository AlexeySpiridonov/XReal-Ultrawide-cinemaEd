import CoreLocation
import MapKit
import SwiftUI

/// The phone side: status, HUD preview, what to show, target on a map.
struct PhoneView: View {
    @ObservedObject private var model = HUDModel.shared
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Glasses", value: model.glassesConnected ? "Connected" : "Not connected")
                    LabeledContent("Location", value: authorizationText)
                    if let location = model.location {
                        LabeledContent("GPS accuracy", value: "±\(Int(location.horizontalAccuracy)) m")
                    }
                    if let road = model.roadName {
                        LabeledContent("Road", value: road)
                    }
                    Toggle("Dim phone screen while glasses are connected", isOn: $model.dimPhoneScreen)
                        .onChange(of: model.dimPhoneScreen) { _, _ in
                            if model.glassesConnected { GlassesSceneDelegate.keepPhoneAwake(true) }
                        }
                } header: {
                    Text("Status")
                } footer: {
                    Text("Do not lock the phone: iOS freezes the glasses' display while the phone is locked. The app keeps the phone awake and dims its screen instead; tap the screen to see it.")
                }

                Section("HUD preview") {
                    HUDPreview()
                }

                Section("Show on the glasses") {
                    Toggle("Speed", isOn: $model.showSpeed)
                    Toggle("Heading", isOn: $model.showHeading)
                    Toggle("Altitude", isOn: $model.showAltitude)
                    Toggle("Target distance and arrow", isOn: $model.showTarget)
                    Toggle("Coordinates", isOn: $model.showCoordinates)
                    Toggle("Clock and GPS accuracy", isOn: $model.showClock)
                    Toggle("Roads on the right", isOn: $model.showMap)
                    if model.showMap {
                        Picker("Road ahead", selection: $model.mapAhead) {
                            Text("100 m").tag(100.0)
                            Text("150 m").tag(150.0)
                            Text("300 m").tag(300.0)
                            Text("500 m").tag(500.0)
                        }
                    }
                }

                Section("Units and sources") {
                    Picker("Speed unit", selection: $model.speedUnit) {
                        ForEach(SpeedUnit.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Heading source", selection: $model.headingSource) {
                        ForEach(HeadingSource.allCases) { Text($0.label).tag($0) }
                    }
                    VStack(alignment: .leading) {
                        Text("HUD size: \(Int(model.hudScale * 100))%")
                        Slider(value: $model.hudScale, in: 0.6...1.6, step: 0.1)
                    }
                }

                Section {
                    targetMap
                        .frame(height: 320)
                        .listRowInsets(EdgeInsets())
                    if let target = model.target {
                        LabeledContent("Target", value: String(format: "%.5f, %.5f", target.latitude, target.longitude))
                        Button("Clear target", role: .destructive) { model.target = nil }
                    }
                } header: {
                    Text("Target (tap the map)")
                } footer: {
                    Text("The HUD shows the distance to the target and an arrow pointing at it relative to your heading.")
                }
            }
            .navigationTitle("GlassesHUD")
        }
    }

    private var authorizationText: String {
        switch model.authorization {
        case .authorizedAlways, .authorizedWhenInUse: return "Allowed"
        case .denied, .restricted: return "Denied (enable in Settings)"
        default: return "Not asked yet"
        }
    }

    private var targetMap: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                UserAnnotation()
                if let target = model.target {
                    Marker("Target", systemImage: "flag.fill", coordinate: target)
                        .tint(.orange)
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .onTapGesture { point in
                if let coordinate = proxy.convert(point, from: .local) {
                    model.target = coordinate
                }
            }
        }
    }
}

/// The HUD rendered at glasses resolution, scaled down to fit the phone.
private struct HUDPreview: View {
    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / 1920
            HUDView()
                .frame(width: 1920, height: 1080)
                .scaleEffect(scale, anchor: .topLeading)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipped()
        .cornerRadius(8)
    }
}

#Preview {
    PhoneView()
}
