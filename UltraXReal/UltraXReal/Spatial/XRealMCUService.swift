import CoreGraphics
import Foundation

/// Talks to the glasses' MCU over USB HID. Every call must run on `GlassesHID.queue`
/// and blocks for up to a few seconds while waiting for the glasses to reply.
///
/// Display mode codes verified on XReal Air 2 Pro:
///   0x03 = side-by-side 3D, the glasses re-enumerate as 3840x1080@60 (takes 8–25 s)
///   0x0B = 2D 1920x1080@120 (the factory default on this model)
/// The open Linux driver also lists 0x08 / 0x09 as side-by-side (72 / 90 Hz) and 0x01 as 2D 60 Hz;
/// those are not verified here, so the code that the glasses report is remembered as "their 2D mode"
/// only while the panel is actually presenting a narrow (2D) display.
enum XRealMCUService {

    static let sideBySideMode: UInt8 = 0x03
    /// Codes known to mean side-by-side 3D (0x03 verified, 0x08 / 0x09 from the Linux driver).
    static let sideBySideCodes: Set<UInt8> = [0x03, 0x08, 0x09]
    private static let fallback2DMode: UInt8 = 0x01
    private static let lastKnown2DModeKey = "glasses2DMode"

    static func isSideBySide(code: UInt8) -> Bool {
        sideBySideCodes.contains(code)
    }

    /// The 2D mode code these glasses reported last time (persisted), or the Linux driver's 2D 60 Hz code.
    static var default2DMode: UInt8 {
        let stored = UserDefaults.standard.integer(forKey: lastKnown2DModeKey)
        return stored > 0 ? UInt8(stored) : fallback2DMode
    }

    /// Current display mode code, nil on failure. Remembers the code as the glasses' 2D mode
    /// when it is not a known side-by-side code and the panel is currently 2D.
    static func readDisplayMode() -> UInt8? {
        dispatchPrecondition(condition: .onQueue(GlassesHID.queue))
        let value = device_mcu_get_display_mode()
        guard value >= 0 else { return nil }
        let mode = UInt8(value)
        if !isSideBySide(code: mode), !DisplayMirrorHelper.isXRealSideBySide() {
            UserDefaults.standard.set(Int(mode), forKey: lastKnown2DModeKey)
        }
        return mode
    }

    /// Asks the glasses to switch mode. With `verify` the mode is read back after a short pause.
    @discardableResult
    static func setDisplayMode(_ mode: UInt8, verify: Bool = true) -> Bool {
        dispatchPrecondition(condition: .onQueue(GlassesHID.queue))
        guard device_mcu_set_display_mode(mode) else {
            print("[MCU] glasses did not acknowledge display mode 0x\(String(mode, radix: 16))")
            return false
        }
        guard verify else { return true }
        Thread.sleep(forTimeInterval: 0.3)
        guard let readBack = readDisplayMode() else {
            return true  // no read-back available; trust the acknowledgement
        }
        print("[MCU] display mode now 0x\(String(readBack, radix: 16))")
        return readBack == mode
    }

    /// Brightness 0...7, nil on failure.
    static func readBrightness() -> Int? {
        dispatchPrecondition(condition: .onQueue(GlassesHID.queue))
        let value = device_mcu_get_brightness()
        return value >= 0 ? Int(value) : nil
    }

    @discardableResult
    static func setBrightness(_ brightness: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(GlassesHID.queue))
        return device_mcu_set_brightness(UInt8(max(0, min(7, brightness))))
    }
}
