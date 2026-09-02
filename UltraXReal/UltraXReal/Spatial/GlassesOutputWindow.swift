import AppKit

/// A borderless fullscreen window on the glasses' display.
/// Hides itself the moment that display disappears (macOS would otherwise move the window onto
/// the Mac's display) and comes back when the display returns, calling `onHide` / `onShow`.
final class GlassesOutputWindow {

    private(set) var window: NSWindow?
    private(set) var isHiddenBecauseNoGlasses = false

    var onHide: (() -> Void)?
    var onShow: ((NSScreen) -> Void)?

    private let tag: String
    private var screenObserver: NSObjectProtocol?

    init(tag: String) {
        self.tag = tag
    }

    deinit {
        close()
    }

    /// Opens the window on the glasses' screen. Returns that screen, or nil if the glasses' display is absent.
    @discardableResult
    func open(contentView: NSView) -> NSScreen? {
        guard let screen = DisplayMirrorHelper.findXRealScreen() else { return nil }

        contentView.frame = CGRect(origin: .zero, size: screen.frame.size)
        contentView.autoresizingMask = [.width, .height]

        // With `screen:` the content rect is relative to that screen's origin.
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: screen.frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = .black
        window.contentView = contentView
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        self.window = window

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.syncToGlassesScreen()
        }
        return screen
    }

    func close() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        window?.orderOut(nil)
        window = nil
    }

    private func syncToGlassesScreen() {
        guard let window else { return }
        guard let screen = DisplayMirrorHelper.findXRealScreen() else {
            if !isHiddenBecauseNoGlasses {
                isHiddenBecauseNoGlasses = true
                window.orderOut(nil)
                onHide?()
                print("[\(tag)] Glasses display gone, hiding")
            }
            return
        }

        let onRightScreen = window.screen.flatMap(DisplayMirrorHelper.displayID(of:)) == DisplayMirrorHelper.displayID(of: screen)
        if isHiddenBecauseNoGlasses || !onRightScreen {
            window.setFrame(screen.frame, display: true)
            window.orderFront(nil)
            isHiddenBecauseNoGlasses = false
            onShow?(screen)
            print("[\(tag)] Back on the glasses display")
        }
    }
}
