import Foundation

/// All hidapi work (enumerate, open, close, MCU transactions) goes through this one serial queue.
/// hidapi's macOS backend shares a single global manager and the vendored device.c keeps an
/// unsynchronised refcount, so using it from two threads at once crashes. The IMU read loop only
/// blocks in hid_read_timeout on an already-open handle, which is safe alongside this queue.
enum GlassesHID {
    static let queue = DispatchQueue(label: "com.ultraxreal.hid", qos: .userInitiated)

    /// Runs `body` on the HID queue and waits for it. Never call from the queue itself.
    static func sync<T>(_ body: () -> T) -> T {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync(execute: body)
    }
}
