import CSMC
import Foundation

/// One raw reading from an IOHIDEventSystem temperature service.
public struct HIDTemperature: Sendable {
    /// Service index inside this reader (not stable across launches).
    public let index: Int
    public let name: String
    public let location: UInt64
    public let celsius: Double
}

/// Wraps the private IOHIDEventSystemClient temperature API. Create once, read repeatedly.
/// Service names are cached at creation; reading costs one event copy per enabled service.
/// Not thread-safe: own it from a single actor.
public final class HIDTemperatureReader {
    private let handle: OpaquePointer?

    public init() { handle = csmc_hid_create() }
    deinit { csmc_hid_destroy(handle) }

    public var serviceCount: Int { Int(csmc_hid_count(handle)) }

    public func read() -> [HIDTemperature] {
        guard let handle else { return [] }
        let max = 256
        var buf = [csmc_hid_temp](repeating: csmc_hid_temp(), count: max)
        let n = Int(csmc_hid_read(handle, &buf, Int32(max)))
        return buf.prefix(n).map { t in
            let name = withUnsafeBytes(of: t.name) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            return HIDTemperature(index: Int(t.index), name: name, location: t.location, celsius: t.celsius)
        }
    }

    /// Stop polling these services (saves most of the read time for unused channels).
    public func disable(_ indices: some Sequence<Int>) {
        for i in indices { csmc_hid_set_enabled(handle, Int32(i), false) }
    }
}
