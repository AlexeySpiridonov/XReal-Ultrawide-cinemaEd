import Foundation

/// Talks to the glasses' MCU over USB HID. Every call blocks for up to a few seconds
/// while waiting for the glasses to reply, so call it off the main thread.
///
/// Display mode codes verified on XReal Air 2 Pro:
///   0x03 = side-by-side 3D, the glasses re-enumerate as 3840x1080@60 (takes ~25 s)
///   0x0B = 2D 1920x1080@120 (the factory default on this model)
///   0x01 = 2D 1920x1080@60 (per the open Linux driver)
/// Other codes from the Linux driver are not verified for this model, so the API works with raw bytes
/// and the caller decides what is side-by-side by looking at the display width.
enum XRealMCUService {

    static let sideBySideMode: UInt8 = 0x03
    private static let fallback2DMode: UInt8 = 0x01
    private static let lastKnown2DModeKey = "glasses2DMode"

    /// The 2D mode code these glasses reported last time (persisted), or the Linux driver's 2D 60 Hz code.
    static var default2DMode: UInt8 {
        let stored = UserDefaults.standard.integer(forKey: lastKnown2DModeKey)
        return stored > 0 ? UInt8(stored) : fallback2DMode
    }

    /// Current display mode code, nil on failure. Remembers non-SBS codes as the glasses' 2D mode.
    static func readDisplayMode() -> UInt8? {
        let value = device_mcu_get_display_mode()
        guard value >= 0 else { return nil }
        let mode = UInt8(value)
        if mode != sideBySideMode {
            UserDefaults.standard.set(Int(mode), forKey: lastKnown2DModeKey)
        }
        return mode
    }

    /// Asks the glasses to switch mode and verifies by reading the mode back.
    @discardableResult
    static func setDisplayMode(_ mode: UInt8) -> Bool {
        guard device_mcu_set_display_mode(mode) else {
            print("[MCU] glasses did not acknowledge display mode 0x\(String(mode, radix: 16))")
            return false
        }
        Thread.sleep(forTimeInterval: 0.3)
        guard let readBack = readDisplayMode() else {
            return true  // no read-back available; trust the acknowledgement
        }
        print("[MCU] display mode now 0x\(String(readBack, radix: 16))")
        return readBack == mode
    }

    /// Brightness 0...7, nil on failure.
    static func readBrightness() -> Int? {
        let value = device_mcu_get_brightness()
        return value >= 0 ? Int(value) : nil
    }

    @discardableResult
    static func setBrightness(_ brightness: Int) -> Bool {
        device_mcu_set_brightness(UInt8(max(0, min(7, brightness))))
    }
}
