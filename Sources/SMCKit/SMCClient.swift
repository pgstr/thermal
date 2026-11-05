import CSMC
import Foundation

public enum SMCError: Error, CustomStringConvertible {
    case cannotOpen
    case keyNotFound(String)
    case readFailed(String, code: Int32)

    public var description: String {
        switch self {
        case .cannotOpen: "cannot open AppleSMC"
        case .keyNotFound(let k): "SMC key \(k) not found"
        case .readFailed(let k, let code): "SMC read \(k) failed (0x\(String(code, radix: 16)))"
        }
    }
}

/// Read-only connection to the AppleSMC. Not thread-safe: own it from a single actor.
public final class SMCClient {
    private let conn: UInt32

    public init() throws {
        conn = csmc_open()
        if conn == 0 { throw SMCError.cannotOpen }
    }

    deinit { csmc_close(conn) }

    public func read(_ key: String) throws -> SMCValue {
        var v = csmc_value()
        let rc = key.withCString { csmc_read(conn, $0, &v) }
        if rc == 0x84 { throw SMCError.keyNotFound(key) }
        if rc != 0 { throw SMCError.readFailed(key, code: rc) }
        let type = withUnsafeBytes(of: v.type) { String(decoding: $0.prefix(4), as: UTF8.self) }
        let bytes = withUnsafeBytes(of: v.bytes) { Array($0.prefix(Int(v.size))) }
        return SMCValue(key: key, type: type, bytes: bytes)
    }

    /// Convenience: numeric value or nil when the key is missing or not numeric.
    public func number(_ key: String) -> Double? { (try? read(key))?.number }

    /// All key names the SMC enumerates (~3600 on M5 Pro). Slow-ish (~ms per key); call rarely.
    public func allKeys() -> [String] {
        var count: UInt32 = 0
        guard csmc_key_count(conn, &count) == 0 else { return [] }
        var keys: [String] = []
        keys.reserveCapacity(Int(count))
        for i in 0..<count {
            var buf: (CChar, CChar, CChar, CChar, CChar) = (0, 0, 0, 0, 0)
            let rc = withUnsafeMutablePointer(to: &buf) {
                $0.withMemoryRebound(to: CChar.self, capacity: 5) { csmc_key_at(conn, i, $0) }
            }
            if rc == 0 {
                keys.append(withUnsafeBytes(of: buf) { String(decoding: $0.prefix(4), as: UTF8.self) })
            }
        }
        return keys
    }
}
