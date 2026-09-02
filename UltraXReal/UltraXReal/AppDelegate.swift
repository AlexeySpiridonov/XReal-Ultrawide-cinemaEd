import AppKit
import Combine
import UniformTypeIdentifiers

/// What the glasses are doing right now. Exactly one mode is active at a time.
enum GlassesMode: Int {
    case extraDisplay = 1   // glasses are a regular extended display, 1:1
    case mirror = 2         // glasses mirror the built-in display
    case cinema = 3         // a video fullscreen on the glasses, sound in the glasses
    case demo = 4         // stereo 3D demo: standing inside Stonehenge

    var title: String {
        switch self {
        case .extraDisplay: return "Extended Display"
        case .mirror: return "Mirror Main Display"
        case .demo: return "Demo: 3D"
        case .cinema: return "Cinema…"
        }
    }

    var usesStereo: Bool { self == .demo }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let settings = Settings.shared
    private var globalHotkeyMonitor: Any?

    private var mode: GlassesMode = .extraDisplay

    // Mirror mode
    private var mirroredGlassesID: CGDirectDisplayID?

    // Stereo mode (3D demo)
    private var imuService: XRealIMUService?
    private var stereoRenderer: StereoSceneRenderer?
    private var stereoStatus: String?
    private var stereoPreviousMode: UInt8?
    private var stereoEnableGeneration = 0

    // Cinema
    private var cinemaURL: URL?
    private var cinemaPlayer: CinemaPlayer?
    private var tapDetector: TapDetector?
    private var tapSubscription: AnyCancellable?

    // Glasses presence watchdog
    private var glassesWatchdog: Timer?
    private var missedGlassesChecks = 0
    private var glassesDisconnectedNotice = false

    private var isStereoActive: Bool { stereoRenderer != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        setupRecenterHotkey()
        setupDisplayReconfigurationCallback()
        startGlassesWatchdog()
        DisplayMirrorHelper.applyBestModeToXReal()
        buildMenu()

        // Launch arguments for development: `--stereo` starts the 3D demo, `--cinema <file>` the cinema.
        let args = CommandLine.arguments
        if args.contains("--stereo") {
            switchTo(.demo)
        } else if let index = args.firstIndex(of: "--cinema"), index + 1 < args.count {
            cinemaURL = URL(fileURLWithPath: args[index + 1])
            switchTo(.cinema, askForFile: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        glassesWatchdog?.invalidate()
        leaveCurrentMode(exiting: true)
        if let monitor = globalHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, nil)
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        let imuAvailable = XRealIMUService.isDeviceAvailable()

        for candidate in [GlassesMode.extraDisplay, .mirror, .cinema, .demo] {
            var title = candidate.title
            if candidate == .cinema, mode == .cinema, let cinemaURL {
                title = "Cinema: \(cinemaURL.lastPathComponent)"
            }
            let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "\(candidate.rawValue)")
            item.target = self
            item.tag = candidate.rawValue
            item.state = candidate == mode ? .on : .off
            if candidate.usesStereo && !imuAvailable && candidate != mode {
                item.isEnabled = false
                item.toolTip = "Connect XReal Air via USB-C (IMU not detected)"
            }
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // Cinema transport panel
        if let cinemaPlayer {
            let panelItem = NSMenuItem()
            panelItem.view = CinemaControlView(
                player: cinemaPlayer,
                onStop: { [weak self] in
                    self?.statusItem.menu?.cancelTracking()
                    self?.switchTo(.extraDisplay)
                },
                onChanged: { [weak self] in self?.updateIcon() }
            )
            menu.addItem(panelItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Recenter (only while the stereo scene is running)
        if isStereoActive {
            let recenterItem = NSMenuItem(title: "Recenter View (Cmd+Shift+R)", action: #selector(recenter), keyEquivalent: "")
            recenterItem.target = self
            menu.addItem(recenterItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Glasses display mode: current mode as info, plus a fix-it action when it is not the best one.
        let glassesID = DisplayMirrorHelper.findXRealDisplay()
        if let glassesID, let current = CGDisplayCopyDisplayMode(glassesID) {
            let info = NSMenuItem(title: "Glasses: \(Self.describe(current))", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)

            if let best = DisplayMirrorHelper.bestMode(for: glassesID),
               best.pixelWidth != current.pixelWidth || best.pixelHeight != current.pixelHeight || best.refreshRate != current.refreshRate {
                let fixItem = NSMenuItem(title: "Switch Glasses to \(Self.describe(best))",
                                         action: #selector(applyBestGlassesMode), keyEquivalent: "")
                fixItem.target = self
                menu.addItem(fixItem)
            }
        } else {
            let info = NSMenuItem(title: "Glasses: not connected", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }

        menu.addItem(NSMenuItem.separator())

        // Status
        var statusLines: [String] = []
        if let renderer = stereoRenderer {
            let stereo = renderer.eyeCount == 2 ? "SBS" : "mono, glasses did not switch to 3D"
            statusLines.append("Stereo: active (\(renderer.fps) fps, \(stereo))")
            statusLines.append("IMU: \(imuService?.isConnected == true ? "connected" : "disconnected")")
        } else if let stereoStatus {
            statusLines.append("Stereo: \(stereoStatus)")
        } else if mode == .cinema {
            if let cinemaPlayer {
                statusLines.append("Audio: \(cinemaPlayer.audioDeviceName ?? "system default output")")
                statusLines.append("Double-tap the glasses: pause / resume")
            } else {
                statusLines.append("Cinema: glasses display not found")
            }
        } else if mode == .mirror {
            statusLines.append(mirroredGlassesID != nil ? "Mirror: main display → glasses" : "Mirror: glasses not found")
        } else if glassesDisconnectedNotice {
            statusLines.append("Glasses unplugged, modes stopped")
        } else if glassesID == nil {
            statusLines.append("Connect XReal Air via USB-C to enable the modes")
        }
        if !statusLines.isEmpty {
            for line in statusLines {
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
        }

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = settings.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About UltraXReal", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private static func describe(_ mode: CGDisplayMode) -> String {
        "\(mode.pixelWidth)×\(mode.pixelHeight) @ \(Int(mode.refreshRate)) Hz"
    }

    // MARK: - Mode switching

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let selected = GlassesMode(rawValue: sender.tag) else { return }
        switchTo(selected)
    }

    private func switchTo(_ newMode: GlassesMode, askForFile: Bool = true) {
        // Re-selecting the cinema lets the user pick another file; other modes are idempotent.
        if newMode == mode && newMode != .cinema { return }

        if newMode == .cinema && askForFile {
            guard let url = chooseVideoFile() else { return }
            cinemaURL = url
        }

        leaveCurrentMode()
        mode = newMode
        glassesDisconnectedNotice = false

        switch newMode {
        case .extraDisplay:
            enableExtraDisplay()
        case .mirror:
            enableMirror()
        case .demo:
            enableStereo()
        case .cinema:
            guard let cinemaURL else { mode = .extraDisplay; break }
            enableCinema(url: cinemaURL)
        }

        updateIcon()
        buildMenu()
    }

    /// Undoes whatever the current mode did to the glasses.
    private func leaveCurrentMode(exiting: Bool = false) {
        switch mode {
        case .mirror:
            disableMirror()
        case .demo:
            disableStereo(waitForGlasses: exiting)
        case .cinema:
            disableCinema()
        case .extraDisplay:
            break
        }
        // A stereo enable may still be pending (glasses switched, display not back yet).
        if stereoPreviousMode != nil {
            disableStereo(waitForGlasses: exiting)
        }
    }

    // MARK: - Mode 1: extra display

    private func enableExtraDisplay() {
        if let glassesID = DisplayMirrorHelper.findXRealDisplay() {
            DisplayMirrorHelper.unmirror(displayID: glassesID)
            DisplayMirrorHelper.applyBestMode(to: glassesID)
        }
    }

    // MARK: - Mode 2: mirror

    private func enableMirror() {
        guard let glassesID = DisplayMirrorHelper.findXRealDisplay() else {
            mirroredGlassesID = nil
            return
        }
        let mainID = CGMainDisplayID()
        if DisplayMirrorHelper.mirror(virtualDisplayID: mainID, onto: glassesID) {
            mirroredGlassesID = glassesID
        } else {
            print("[Mirror] Failed to mirror display \(mainID) onto glasses \(glassesID)")
            mirroredGlassesID = nil
        }
    }

    private func disableMirror() {
        if let glassesID = mirroredGlassesID {
            DisplayMirrorHelper.unmirror(displayID: glassesID)
            mirroredGlassesID = nil
        }
    }

    // MARK: - Mode 4: cinema

    private func enableCinema(url: URL) {
        if let glassesID = DisplayMirrorHelper.findXRealDisplay() {
            DisplayMirrorHelper.unmirror(displayID: glassesID)
            DisplayMirrorHelper.applyBestMode(to: glassesID)
        }
        let player = CinemaPlayer(url: url)
        guard player.start() else {
            cinemaPlayer = nil
            return
        }
        cinemaPlayer = player

        // Double tap on the glasses toggles pause. Needs the IMU stream for the accelerometer.
        let imu = XRealIMUService()
        imu.start()
        imuService = imu

        let detector = TapDetector()
        detector.onDoubleTap = { [weak self] in
            self?.cinemaPlayer?.togglePause()
        }
        tapDetector = detector
        tapSubscription = imu.accelerationSubject.sink { sample in
            detector.process(time: sample.time, magnitude: sample.magnitude)
        }
    }

    private func disableCinema() {
        tapSubscription?.cancel()
        tapSubscription = nil
        tapDetector = nil
        imuService?.stop()
        imuService = nil
        cinemaPlayer?.stop()
        cinemaPlayer = nil
    }

    private func chooseVideoFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a video for the cinema"
        panel.prompt = "Watch"
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Mode 4: stereo 3D demo

    private func enableStereo() {
        // Already side-by-side if the glasses currently present a 3840-wide panel.
        let alreadySBS: Bool
        if let glassesID = DisplayMirrorHelper.findXRealDisplay() {
            alreadySBS = CGDisplayPixelsWide(glassesID) >= 3000
        } else {
            alreadySBS = false
        }

        stereoStatus = "switching glasses to 3D…"
        buildMenu()
        stereoEnableGeneration += 1
        let generation = stereoEnableGeneration

        // MCU calls block while waiting for the glasses, keep them off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let previous = XRealMCUService.readDisplayMode()
            print("[Stereo] Glasses display mode before: \(previous.map { "0x" + String($0, radix: 16) } ?? "unknown")")

            let switched = alreadySBS || XRealMCUService.setDisplayMode(XRealMCUService.sideBySideMode)

            DispatchQueue.main.async {
                guard let self, generation == self.stereoEnableGeneration else { return }
                self.stereoPreviousMode = alreadySBS ? nil : previous
                if !switched {
                    print("[Stereo] Glasses did not switch to SBS, continuing in mono")
                }
                self.stereoStatus = switched ? "waiting for the display to reconnect (up to a minute)…" : "glasses did not switch to 3D, starting mono"
                self.buildMenu()
                // The glasses take 8–25 s to come back as a 3840x1080 display.
                self.waitForGlassesDisplay(minWidth: switched ? 3000 : 0, attempts: 60) { [weak self] in
                    guard let self, generation == self.stereoEnableGeneration else { return }
                    self.startStereoPipeline()
                }
            }
        }
    }

    /// Polls until the glasses' display is back (they re-enumerate after a mode switch)
    /// and wide enough, applying the best mode along the way. Always calls completion.
    private func waitForGlassesDisplay(minWidth: Int, attempts: Int, completion: @escaping () -> Void) {
        if let glassesID = DisplayMirrorHelper.findXRealDisplay() {
            DisplayMirrorHelper.applyBestMode(to: glassesID)
            if CGDisplayPixelsWide(glassesID) >= minWidth {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: completion)
                return
            }
        }
        guard attempts > 0 else {
            print("[Stereo] Timed out waiting for the glasses' display")
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.waitForGlassesDisplay(minWidth: minWidth, attempts: attempts - 1, completion: completion)
        }
    }

    private func startStereoPipeline() {
        let imu = XRealIMUService()
        imu.start()
        imuService = imu

        let renderer = StereoSceneRenderer(imuService: imu)
        guard renderer.start() else {
            stereoStatus = "glasses display not found"
            imu.stop()
            imuService = nil
            restoreGlassesDisplayMode()
            buildMenu()
            return
        }

        stereoRenderer = renderer
        stereoStatus = nil
        updateIcon()
        buildMenu()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            imu.recenter()
        }
    }

    /// - Parameter waitForGlasses: restore the glasses' 2D mode on the current thread
    ///   (needed when the process is about to exit).
    private func disableStereo(waitForGlasses: Bool = false) {
        stereoEnableGeneration += 1  // cancels a pending enable
        stereoRenderer?.stop()
        stereoRenderer = nil
        imuService?.stop()
        imuService = nil
        stereoStatus = nil

        restoreGlassesDisplayMode(synchronously: waitForGlasses)
    }

    /// Returns the glasses to the 2D mode they were in before the stereo mode.
    /// Does nothing if the glasses were already side-by-side when it started.
    private func restoreGlassesDisplayMode(synchronously: Bool = false) {
        guard let previous = stereoPreviousMode else { return }
        stereoPreviousMode = nil
        let target = previous == XRealMCUService.sideBySideMode ? XRealMCUService.default2DMode : previous
        if synchronously {
            XRealMCUService.setDisplayMode(target)
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                XRealMCUService.setDisplayMode(target)
            }
        }
    }

    @objc private func recenter() {
        stereoRenderer?.recenter()
    }

    // MARK: - Glasses display

    @objc private func applyBestGlassesMode() {
        DisplayMirrorHelper.applyBestModeToXReal()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.buildMenu()
        }
    }

    /// Switches the glasses to their best mode whenever they get (re)connected.
    private func setupDisplayReconfigurationCallback() {
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, nil)
    }

    fileprivate func handleDisplayAdded(_ displayID: CGDirectDisplayID) {
        guard displayID == DisplayMirrorHelper.findXRealDisplay() else { return }
        // Give macOS a moment to finish bringing the display up
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            DisplayMirrorHelper.applyBestMode(to: displayID)
            self.glassesDisconnectedNotice = false

            // Glasses that were unplugged mid-stereo come back side-by-side; put them back to 2D.
            if !self.mode.usesStereo, self.stereoPreviousMode == nil, CGDisplayPixelsWide(displayID) >= 3000 {
                print("[Glasses] Reconnected in side-by-side mode, restoring 2D")
                DispatchQueue.global(qos: .userInitiated).async {
                    XRealMCUService.setDisplayMode(XRealMCUService.default2DMode)
                }
            }
            self.buildMenu()
        }
    }

    fileprivate func handleDisplayRemoved(_ displayID: CGDirectDisplayID) {
        // Output windows hide themselves at once (see CinemaPlayer / StereoSceneRenderer).
        // The display also disappears during a 2D/SBS switch, so decide by USB presence:
        // no USB device one second later and no stereo switch in progress means unplugged.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            let stereoSwitchInProgress = self.stereoPreviousMode != nil && self.stereoRenderer == nil
            if !stereoSwitchInProgress, !XRealIMUService.isDeviceAvailable() {
                self.handleGlassesDisconnected()
            } else {
                self.checkGlassesPresence()
            }
        }
    }

    // MARK: - Glasses watchdog

    /// Polls USB presence of the glasses; three misses in a row count as unplugged.
    private func startGlassesWatchdog() {
        glassesWatchdog = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkGlassesPresence()
        }
    }

    private func checkGlassesPresence() {
        let somethingActive = mode != .extraDisplay || stereoPreviousMode != nil || cinemaPlayer != nil
        guard somethingActive else {
            missedGlassesChecks = 0
            if glassesDisconnectedNotice, XRealIMUService.isDeviceAvailable() {
                glassesDisconnectedNotice = false
                buildMenu()
            }
            return
        }
        if XRealIMUService.isDeviceAvailable() {
            missedGlassesChecks = 0
            if glassesDisconnectedNotice {
                glassesDisconnectedNotice = false
                buildMenu()
            }
            return
        }
        missedGlassesChecks += 1
        if missedGlassesChecks >= 3 {
            missedGlassesChecks = 0
            handleGlassesDisconnected()
        }
    }

    /// Shuts down everything that touches the glasses without trying to talk to them.
    private func handleGlassesDisconnected() {
        guard mode != .extraDisplay || stereoPreviousMode != nil || cinemaPlayer != nil else { return }
        print("[Glasses] Unplugged, shutting down \(mode.title)")
        stereoEnableGeneration += 1     // cancel a pending stereo enable
        stereoPreviousMode = nil        // nothing to restore, the glasses are gone
        leaveCurrentMode()
        mode = .extraDisplay
        glassesDisconnectedNotice = true
        updateIcon()
        buildMenu()
    }

    // MARK: - Misc actions

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        settings.launchAtLogin.toggle()
        sender.state = settings.launchAtLogin ? .on : .off
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "UltraXReal",
            .applicationVersion: "3.0.0",
            .credits: NSAttributedString(
                string: "Open-source app for XReal Air glasses.\nModes: extended display, mirror, 3D demo, cinema.\nhttps://github.com/AlexeySpiridonov/XReal-Ultrawide-cinemaEd",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            )
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        leaveCurrentMode(exiting: true)
        mode = .extraDisplay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Global hotkey

    private func setupRecenterHotkey() {
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Cmd+Shift+R (keyCode 15 = R)
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 15 {
                self?.recenter()
            }
        }
    }

    // MARK: - Icon

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol: String
        let color: NSColor?
        switch mode {
        case .extraDisplay:
            symbol = "display"; color = nil
        case .mirror:
            symbol = "rectangle.on.rectangle"; color = .systemGreen
        case .demo:
            symbol = "cube"; color = .systemPurple
        case .cinema:
            symbol = "film"; color = .systemOrange
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "UltraXReal: \(mode.title)")
        if let color {
            button.image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
        } else {
            button.image = image
            button.image?.isTemplate = true
        }
    }
}

private func displayReconfigurationCallback(_ display: CGDirectDisplayID,
                                            _ flags: CGDisplayChangeSummaryFlags,
                                            _ userInfo: UnsafeMutableRawPointer?) {
    if flags.contains(.addFlag) {
        DispatchQueue.main.async {
            (NSApp.delegate as? AppDelegate)?.handleDisplayAdded(display)
        }
    } else if flags.contains(.removeFlag) {
        DispatchQueue.main.async {
            (NSApp.delegate as? AppDelegate)?.handleDisplayRemoved(display)
        }
    }
}
