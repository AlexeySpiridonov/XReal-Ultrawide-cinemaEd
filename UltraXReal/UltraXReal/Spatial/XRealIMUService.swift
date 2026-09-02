import Combine
import Foundation
import IOKit
import QuartzCore
import simd

/// Wraps the vendored XReal IMU driver: reads gyroscope + accelerometer over USB HID,
/// runs Madgwick sensor fusion and exposes the head orientation and linear acceleration.
///
/// The read loop owns the device: it opens it (on the shared HID queue), reads until the
/// device goes away, closes it and then keeps trying to reopen once a second until `stop()`.
/// So a transient re-enumeration (sleep/wake, loose cable, the glasses' own 2D/3D button)
/// heals itself, and `stop()` waits for the loop to finish before returning.
final class XRealIMUService {

    /// Main-thread readable.
    private(set) var isConnected = false

    /// Linear acceleration (gravity removed) magnitude in g, with the host timestamp. Sent per IMU sample
    /// on the IMU thread.
    let accelerationSubject = PassthroughSubject<(time: TimeInterval, magnitude: Float), Never>()

    private let stateLock = NSLock()
    private var _isRunning = false
    private var _orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var _reference = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var _hasReference = false

    private let readQueue = DispatchQueue(label: "com.ultraxreal.imu", qos: .userInteractive)

    deinit {
        stop()
    }

    // MARK: - Public

    /// Check if any XReal glasses are connected, via the IOKit registry (thread-safe, no hidapi).
    static func isDeviceAvailable() -> Bool {
        // The glasses expose several HID interfaces (IMU, MCU) under their USB vendor ID.
        guard let matching = IOServiceMatching("IOHIDDevice") else { return false }
        (matching as NSMutableDictionary)[kIOPropertyMatchKey] = ["VendorID": Int(xreal_vendor_id)]

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }

        let first = IOIteratorNext(iterator)
        guard first != 0 else { return false }
        IOObjectRelease(first)
        return true
    }

    private var isRunning: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isRunning }
        set { stateLock.lock(); _isRunning = newValue; stateLock.unlock() }
    }

    /// Latest orientation from the sensor fusion.
    var orientation: simd_quatf {
        stateLock.lock(); defer { stateLock.unlock() }
        return _orientation
    }

    /// Orientation relative to the reference set by `recenter()` (identity if never recentered).
    var relativeOrientation: simd_quatf {
        stateLock.lock(); defer { stateLock.unlock() }
        return _hasReference ? _reference.inverse * _orientation : _orientation
    }

    /// Capture the current orientation as the "zero" reference point.
    func recenter() {
        stateLock.lock()
        _reference = _orientation
        _hasReference = true
        stateLock.unlock()
    }

    /// Start reading on a background thread; reconnects automatically until `stop()`.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        readQueue.async { self.runLoop() }
    }

    /// Stop reading and close the device. Waits for the read loop to exit.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        readQueue.sync {}  // the loop closes the device itself before returning
        setConnected(false)
    }

    // MARK: - Read loop (readQueue)

    private func runLoop() {
        while isRunning {
            guard let device = openDevice() else {
                // Glasses not present: retry in a second, but stay responsive to stop().
                for _ in 0..<10 where isRunning { Thread.sleep(forTimeInterval: 0.1) }
                continue
            }
            setConnected(true)
            readUntilError(device)
            closeDevice(device)
            setConnected(false)
            if isRunning {
                print("[IMU] Device lost, will reconnect")
            }
        }
    }

    private func openDevice() -> UnsafeMutablePointer<device_imu_type>? {
        GlassesHID.sync {
            let device = UnsafeMutablePointer<device_imu_type>.allocate(capacity: 1)
            device.initialize(to: device_imu_type())
            let err = device_imu_open(device) { _, _, _ in }
            guard err == DEVICE_IMU_ERROR_NO_ERROR else {
                device.deallocate()
                return nil
            }
            return device
        }
    }

    private func closeDevice(_ device: UnsafeMutablePointer<device_imu_type>) {
        GlassesHID.sync {
            device_imu_close(device)
            device.deallocate()
        }
    }

    private func readUntilError(_ device: UnsafeMutablePointer<device_imu_type>) {
        while isRunning {
            let err = device_imu_read(device, 16)  // 16 ms timeout
            if err == DEVICE_IMU_ERROR_UNPLUGGED {
                return
            }
            guard err == DEVICE_IMU_ERROR_NO_ERROR, let ahrs = device.pointee.ahrs else { continue }

            let q = device_imu_get_orientation(ahrs)
            stateLock.lock()
            _orientation = simd_quatf(ix: q.x, iy: q.y, iz: q.z, r: q.w)
            stateLock.unlock()

            let a = device_imu_get_linear_acceleration(ahrs)
            let magnitude = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            accelerationSubject.send((time: CACurrentMediaTime(), magnitude: magnitude))
        }
    }

    private func setConnected(_ connected: Bool) {
        if Thread.isMainThread {
            isConnected = connected
        } else {
            DispatchQueue.main.async { [weak self] in self?.isConnected = connected }
        }
    }
}
