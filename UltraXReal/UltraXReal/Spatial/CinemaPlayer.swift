import AppKit
import AVFoundation
import CoreAudio

/// Plays a video fullscreen on the glasses' display with sound routed to the glasses' speakers.
/// Plain 2D: no head tracking, no side-by-side, the glasses stay a normal display.
final class CinemaPlayer {

    let url: URL
    private let output = GlassesOutputWindow(tag: "Cinema")
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var wasPlayingBeforeHide = false

    private(set) var audioDeviceName: String?

    init(url: URL) {
        self.url = url
    }

    deinit {
        stop()
    }

    /// Returns false if the glasses' display is not present.
    @discardableResult
    func start() -> Bool {
        guard let screen = DisplayMirrorHelper.findXRealScreen() else {
            print("[Cinema] XReal Air display not found")
            return false
        }

        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        if let device = Self.findGlassesAudioDevice() {
            player.audioOutputDeviceUniqueID = device.uid
            audioDeviceName = device.name
            print("[Cinema] Audio → \(device.name)")
        }
        self.player = player

        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = view.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        playerLayer.videoGravity = .resizeAspect
        view.layer?.addSublayer(playerLayer)

        guard output.open(contentView: view) != nil else {
            return false
        }
        // Pause while the glasses' display is away so no sound leaks to the Mac; resume when it is back.
        output.onHide = { [weak self] in
            guard let self, let player = self.player else { return }
            self.wasPlayingBeforeHide = player.rate > 0
            player.pause()
        }
        output.onShow = { [weak self] _ in
            guard let self, self.wasPlayingBeforeHide else { return }
            self.player?.play()
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { _ in
            print("[Cinema] Playback finished")
        }

        player.play()
        return true
    }

    func stop() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        player = nil
        output.close()
    }

    var isPlaying: Bool { (player?.rate ?? 0) > 0 }

    func togglePause() {
        guard let player else { return }
        if player.rate > 0 { player.pause() } else { player.play() }
    }

    // MARK: - Transport

    /// Duration in seconds, 0 until the item has loaded.
    var duration: TimeInterval {
        guard let item = player?.currentItem else { return 0 }
        let d = item.duration
        return d.isNumeric ? max(0, CMTimeGetSeconds(d)) : 0
    }

    var currentTime: TimeInterval {
        guard let player else { return 0 }
        let t = player.currentTime()
        return t.isNumeric ? max(0, CMTimeGetSeconds(t)) : 0
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600))
    }

    /// 0...1
    var volume: Float {
        get { player?.volume ?? 1 }
        set { player?.volume = max(0, min(1, newValue)) }
    }

    // MARK: - Helpers

    /// The glasses' USB audio output, found by name.
    private static func findGlassesAudioDevice() -> (uid: String, name: String)? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return nil
        }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else {
            return nil
        }

        for device in devices {
            guard let name = stringProperty(device, kAudioObjectPropertyName),
                  name.lowercased().contains("xreal") || name.lowercased().contains("nreal"),
                  outputChannelCount(device) > 0,
                  let uid = stringProperty(device, kAudioDevicePropertyDeviceUID) else { continue }
            return (uid, name)
        }
        return nil
    }

    private static func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func outputChannelCount(_ device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
