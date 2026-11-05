import Foundation

/// A raw SMC key value plus its type, with decoding helpers.
///
/// On Apple Silicon (verified on M5 Pro / macOS 27) integers are little-endian and `flt ` is a
/// little-endian IEEE float. The legacy fixed-point types (`sp78`, `fpe2`) are big-endian.
public struct SMCValue: Sendable, Equatable {
    public let key: String
    public let type: String
    public let bytes: [UInt8]

    public init(key: String, type: String, bytes: [UInt8]) {
        self.key = key
        self.type = type
        self.bytes = bytes
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    private func le(_ n: Int) -> UInt64? {
        guard bytes.count >= n else { return nil }
        var r: UInt64 = 0
        for i in stride(from: n - 1, through: 0, by: -1) { r = (r << 8) | UInt64(bytes[i]) }
        return r
    }

    private func be(_ n: Int) -> UInt64? {
        guard bytes.count >= n else { return nil }
        return bytes.prefix(n).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    /// Numeric value if the type is a known numeric encoding, otherwise nil.
    public var number: Double? {
        switch type {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let bits = UInt32(le(4)!)
            return Double(Float(bitPattern: bits))
        case "ui8 ", "flag": return bytes.first.map { Double($0) }
        case "ui16": return le(2).map { Double($0) }
        case "ui32": return le(4).map { Double($0) }
        case "ui64": return le(8).map { Double($0) }
        case "si8 ": return bytes.first.map { Double(Int8(bitPattern: $0)) }
        case "si16": return le(2).map { Double(Int16(truncatingIfNeeded: $0)) }
        case "si32": return le(4).map { Double(Int32(truncatingIfNeeded: $0)) }
        case "si64": return le(8).map { Double(Int64(bitPattern: $0)) }
        case "sp78": return be(2).map { Double(Int16(truncatingIfNeeded: $0)) / 256 }
        case "fpe2": return be(2).map { Double($0) / 4 }
        case "ioft": return le(8).map { Double($0) / 65536 }
        default: return nil
        }
    }

    /// Human-readable decoded value (number, flag, or printable string), or "" when unknown.
    public var decoded: String {
        if type == "flag" { return (bytes.first ?? 0) != 0 ? "true" : "false" }
        if type.hasPrefix("ch8") {
            return String(bytes.map { (32..<127).contains($0) ? Character(UnicodeScalar($0)) : "." })
        }
        guard let n = number else { return "" }
        return type == "flt " || type == "sp78" || type == "fpe2" || type == "ioft"
            ? String(format: "%.3f", n) : String(format: "%.0f", n)
    }
}
