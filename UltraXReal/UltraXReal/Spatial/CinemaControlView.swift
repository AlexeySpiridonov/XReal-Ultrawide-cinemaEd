import AppKit

/// Transport controls for the cinema, embedded in the status bar menu:
/// play/pause, stop, seek slider with time, volume slider.
final class CinemaControlView: NSView {

    private weak var player: CinemaPlayer?
    private let onStop: () -> Void
    private let onChanged: () -> Void

    private let titleLabel = NSTextField(labelWithString: "")
    private let playButton = NSButton(title: "", target: nil, action: nil)
    private let stopButton = NSButton(title: "", target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let seekSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let volumeIcon = NSImageView()
    private let volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)

    private var refreshTimer: Timer?
    private var isScrubbing = false

    /// - Parameters:
    ///   - onStop: called when the user presses stop.
    ///   - onChanged: called after play/pause so the owner can refresh other menu items.
    init(player: CinemaPlayer, onStop: @escaping () -> Void, onChanged: @escaping () -> Void) {
        self.player = player
        self.onStop = onStop
        self.onChanged = onChanged
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 118))
        buildControls()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Layout

    private func buildControls() {
        let margin: CGFloat = 14
        let width = bounds.width - margin * 2

        titleLabel.frame = NSRect(x: margin, y: 94, width: width, height: 17)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.stringValue = player?.url.lastPathComponent ?? ""
        addSubview(titleLabel)

        configure(playButton, symbol: "play.fill", tooltip: "Play / pause", action: #selector(togglePlay))
        playButton.frame = NSRect(x: margin, y: 62, width: 30, height: 26)
        addSubview(playButton)

        configure(stopButton, symbol: "stop.fill", tooltip: "Stop: close the cinema", action: #selector(stop))
        stopButton.frame = NSRect(x: margin + 36, y: 62, width: 30, height: 26)
        addSubview(stopButton)

        timeLabel.frame = NSRect(x: margin + 76, y: 66, width: width - 76, height: 17)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.alignment = .right
        timeLabel.textColor = .secondaryLabelColor
        addSubview(timeLabel)

        seekSlider.frame = NSRect(x: margin, y: 36, width: width, height: 20)
        seekSlider.target = self
        seekSlider.action = #selector(seekChanged(_:))
        seekSlider.isContinuous = true
        addSubview(seekSlider)

        volumeIcon.frame = NSRect(x: margin, y: 10, width: 18, height: 18)
        volumeIcon.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Volume")
        volumeIcon.contentTintColor = .secondaryLabelColor
        addSubview(volumeIcon)

        volumeSlider.frame = NSRect(x: margin + 26, y: 9, width: width - 26, height: 20)
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged(_:))
        volumeSlider.isContinuous = true
        volumeSlider.doubleValue = Double(player?.volume ?? 1)
        addSubview(volumeSlider)
    }

    private func configure(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.toolTip = tooltip
        button.target = self
        button.action = action
    }

    // MARK: - Refresh while the menu is open

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        // Menu tracking runs the run loop in event-tracking mode; .common covers it.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        refresh()
    }

    private func refresh() {
        guard let player else { return }
        let symbol = player.isPlaying ? "pause.fill" : "play.fill"
        playButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Play / pause")

        let duration = player.duration
        let current = player.currentTime
        timeLabel.stringValue = "\(Self.format(current)) / \(Self.format(duration))"

        if !isScrubbing {
            seekSlider.maxValue = max(duration, 1)
            seekSlider.doubleValue = current
            seekSlider.isEnabled = duration > 0
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: - Actions

    @objc private func togglePlay() {
        player?.togglePause()
        refresh()
        onChanged()
    }

    @objc private func stop() {
        onStop()
    }

    @objc private func seekChanged(_ sender: NSSlider) {
        // While the mouse is down the slider keeps sending; seek on each change, but do not
        // let the refresh timer fight the thumb until the mouse goes up.
        let dragging = NSApp.currentEvent?.type == .leftMouseDragged || NSApp.currentEvent?.type == .leftMouseDown
        isScrubbing = dragging
        player?.seek(to: sender.doubleValue)
        if !dragging { refresh() }
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        player?.volume = Float(sender.doubleValue)
    }
}
