import Foundation
import ServiceManagement

/// Persists user preferences via UserDefaults.
final class Settings: ObservableObject {

    static let shared = Settings()

    private let defaults = UserDefaults.standard
    private let launchAtLoginKey = "launchAtLogin"

    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: launchAtLoginKey)
            updateLoginItem()
        }
    }

    private init() {
        launchAtLogin = defaults.bool(forKey: launchAtLoginKey)
    }

    private func updateLoginItem() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            print("Failed to update login item: \(error)")
        }
    }
}
