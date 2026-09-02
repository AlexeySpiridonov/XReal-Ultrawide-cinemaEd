import AppKit
import CoreGraphics
import Foundation

/// Finds the glasses' display and configures it: display mode, mirroring, side-by-side detection.
enum DisplayMirrorHelper {

    /// A panel at least this wide is the glasses in side-by-side 3D mode (3840x1080).
    static let sideBySideMinPixelWidth = 3000

    static func isSideBySide(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayPixelsWide(displayID) >= sideBySideMinPixelWidth
    }

    /// True when the glasses are present and currently side-by-side.
    static func isXRealSideBySide() -> Bool {
        findXRealDisplay().map(isSideBySide) ?? false
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The NSScreen of the glasses' display, if present.
    static func findXRealScreen() -> NSScreen? {
        guard let displayID = findXRealDisplay() else { return nil }
        return NSScreen.screens.first { self.displayID(of: $0) == displayID }
    }

    // Known XReal/Nreal vendor IDs (USB vendor ID space)
    private static let xrealVendorIDs: Set<UInt32> = [
        13895, // 0x3647 — XReal Air (observed)
        10462, // 0x28DE — alternate
        7531,  // 0x1D6B — alternate
    ]

    /// Attempts to find the XReal Air display among online displays.
    /// Uses vendor ID matching first, falls back to a 1920×1080 non-builtin heuristic.
    static func findXRealDisplay(excludingDisplayID: CGDirectDisplayID? = nil) -> CGDirectDisplayID? {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0

        let err = CGGetOnlineDisplayList(16, &displayIDs, &displayCount)
        guard err == .success else { return nil }

        // First pass: match by vendor ID
        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            if id == excludingDisplayID { continue }
            if CGDisplayIsBuiltin(id) != 0 { continue }

            let vendor = CGDisplayVendorNumber(id)
            if xrealVendorIDs.contains(vendor) {
                return id
            }
        }

        // Second pass: fall back to the first external 1920×1080 display
        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            if id == excludingDisplayID { continue }
            if CGDisplayIsBuiltin(id) != 0 { continue }

            let width = CGDisplayPixelsWide(id)
            let height = CGDisplayPixelsHigh(id)
            if width == 1920 && height == 1080 {
                return id
            }
        }

        return nil
    }

    /// Picks the best mode for a display: native 1:1 modes only (points == pixels, no HiDPI
    /// or downscaling), then the largest area, then the highest refresh rate.
    /// For XReal Air that is 1920x1080 at the panel's maximum refresh rate.
    static func bestMode(for displayID: CGDirectDisplayID) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return nil
        }
        let native = modes.filter { $0.isUsableForDesktopGUI() && $0.width == $0.pixelWidth && $0.height == $0.pixelHeight }
        let candidates = native.isEmpty ? modes : native
        return candidates.max { a, b in
            let areaA = a.width * a.height
            let areaB = b.width * b.height
            if areaA != areaB { return areaA < areaB }
            return a.refreshRate < b.refreshRate
        }
    }

    static func sameMode(_ a: CGDisplayMode, _ b: CGDisplayMode) -> Bool {
        a.pixelWidth == b.pixelWidth && a.pixelHeight == b.pixelHeight && a.refreshRate == b.refreshRate
    }

    /// Switches the display to its best mode (see `bestMode(for:)`), persisting across reconnects.
    /// Returns true if the mode was already set or has been changed successfully.
    @discardableResult
    static func applyBestMode(to displayID: CGDirectDisplayID) -> Bool {
        guard let best = bestMode(for: displayID) else { return false }

        if let current = CGDisplayCopyDisplayMode(displayID), sameMode(current, best) {
            return true
        }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }

        guard CGConfigureDisplayWithDisplayMode(config, displayID, best, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }

        let ok = CGCompleteDisplayConfiguration(config, .permanently) == .success
        if ok {
            print("[Display] XReal Air \(displayID) switched to \(best.pixelWidth)x\(best.pixelHeight)@\(Int(best.refreshRate))")
        }
        return ok
    }

    /// Finds the XReal Air display and switches it to its best mode.
    @discardableResult
    static func applyBestModeToXReal(excludingDisplayID: CGDirectDisplayID? = nil) -> Bool {
        guard let xrealID = findXRealDisplay(excludingDisplayID: excludingDisplayID) else { return false }
        return applyBestMode(to: xrealID)
    }

    /// Make `targetDisplayID` mirror `sourceDisplayID`.
    @discardableResult
    static func mirror(_ sourceDisplayID: CGDirectDisplayID, onto targetDisplayID: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?

        guard CGBeginDisplayConfiguration(&config) == .success,
              let config else {
            return false
        }

        let mirrorErr = CGConfigureDisplayMirrorOfDisplay(config, targetDisplayID, sourceDisplayID)
        guard mirrorErr == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }

        let completeErr = CGCompleteDisplayConfiguration(config, .forSession)
        return completeErr == .success
    }

    /// Remove mirroring from a display.
    @discardableResult
    static func unmirror(displayID: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?

        guard CGBeginDisplayConfiguration(&config) == .success,
              let config else {
            return false
        }

        let err = CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }

        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }
}

private let kCGNullDirectDisplay: CGDirectDisplayID = 0
