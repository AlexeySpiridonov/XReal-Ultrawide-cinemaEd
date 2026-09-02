import Foundation

/// Detects taps on the glasses from linear-acceleration spikes.
/// A tap is a sharp peak above `threshold` after a quiet spell; two taps within
/// `doubleTapWindow` make a double tap. Head movements are slow and stay below the threshold.
final class TapDetector {

    /// Peak linear acceleration (g) that counts as a tap.
    var threshold: Float = 0.6
    /// Minimum time between two separate taps.
    var debounce: TimeInterval = 0.12
    /// Maximum gap between the two taps of a double tap.
    var doubleTapWindow: TimeInterval = 0.5
    /// Log peaks above this (g) to help tuning.
    var logAbove: Float = 0.3

    var onTap: (() -> Void)?
    var onDoubleTap: (() -> Void)?

    private var lastTapTime: TimeInterval = 0
    private var lastPeakTime: TimeInterval = 0
    private var peakInProgress = false
    private var peakValue: Float = 0

    /// Feed one IMU sample. Safe to call from the IMU read thread; callbacks run on the main thread.
    func process(time: TimeInterval, magnitude: Float) {
        if magnitude > threshold {
            if !peakInProgress {
                peakInProgress = true
                peakValue = magnitude
            } else {
                peakValue = max(peakValue, magnitude)
            }
            return
        }

        guard peakInProgress else {
            if magnitude > logAbove {
                print(String(format: "[Tap] bump %.2f g (below threshold)", magnitude))
            }
            return
        }
        peakInProgress = false

        // Peak just ended: decide whether it was a tap.
        guard time - lastPeakTime > debounce else { return }
        lastPeakTime = time
        print(String(format: "[Tap] tap %.2f g", peakValue))

        if time - lastTapTime < doubleTapWindow {
            lastTapTime = 0
            print("[Tap] double tap")
            DispatchQueue.main.async { [weak self] in self?.onDoubleTap?() }
        } else {
            lastTapTime = time
            DispatchQueue.main.async { [weak self] in self?.onTap?() }
        }
    }
}
