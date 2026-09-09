import UIKit

/// UIKit app lifecycle so the external display (the glasses) gets its own scene and window.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        LocationService.shared.start()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            let config = UISceneConfiguration(name: "Glasses", sessionRole: connectingSceneSession.role)
            config.delegateClass = GlassesSceneDelegate.self
            return config
        }
        let config = UISceneConfiguration(name: "Phone", sessionRole: connectingSceneSession.role)
        config.delegateClass = PhoneSceneDelegate.self
        return config
    }
}

/// The phone's screen: settings, map, HUD preview.
final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: PhoneView())
        window.makeKeyAndVisible()
        self.window = window
    }
}

/// The glasses (external display): the HUD only.
///
/// iOS freezes external-display scenes while the phone is locked, so while the glasses are
/// connected the app keeps the phone awake and turns its screen brightness down to zero instead.
final class GlassesSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private static var savedBrightness: CGFloat?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let controller = UIHostingController(rootView: HUDView())
        controller.view.backgroundColor = .black
        window.rootViewController = controller
        window.isHidden = false
        self.window = window
        HUDModel.shared.glassesConnected = true
        Self.keepPhoneAwake(true)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        HUDModel.shared.glassesConnected = false
        Self.keepPhoneAwake(false)
        window = nil
    }

    static func keepPhoneAwake(_ awake: Bool) {
        UIApplication.shared.isIdleTimerDisabled = awake
        guard let phoneScreen = phoneScreen() else { return }
        if awake {
            if HUDModel.shared.dimPhoneScreen {
                if savedBrightness == nil { savedBrightness = phoneScreen.brightness }
                phoneScreen.brightness = 0
            }
        } else if let saved = savedBrightness {
            phoneScreen.brightness = saved
            savedBrightness = nil
        }
    }

    /// The phone's own screen (not the external one).
    private static func phoneScreen() -> UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication }?
            .screen
    }
}

import SwiftUI
