// Decoders for the fundamental scalar types, in both text and binary formats.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

extension Bool: PostgresDecodable {
    public static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> Bool {
        switch format {
        case .binary:
            guard bytes.count == 1 else { throw postgresDecodeError("Bool", oid: oid, format: format, bytes) }
            return bytes[0] != 0
        case .text:
            switch utf8String(bytes) {
            case "t", "true", "y", "yes", "on", "1": return true
            case "f", "false", "n", "no", "off", "0": return false
            default: throw postgresDecodeError("Bool", oid: oid, format: format, bytes)
            }
        }
    }
}

extension Int16: PostgresDecodable {
    public static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> Int16 {
        switch format {
        case .binary:
            guard bytes.count == 2 else { throw postgresDecodeError("Int16", oid: oid, format: format, bytes) }
            return Int16(bitPattern: WireBinary.uint16(bytes))
        case .text:
            guard let value = parseASCIIInteger(bytes, as: Int16.self) else {
                throw postgresDecodeError("Int16", oid: oid, format: format, bytes)
            }
            return value
        }
    }
}

extension Int32: PostgresDecodable {
    public static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> Int32 {
        switch format {
        case .binary:
            guard bytes.count == 4 else { throw postgresDecodeError("Int32", oid: oid, format: format, bytes) }
            return Int32(bitPattern: WireBinary.uint32(bytes))
        case .text:
            guard let value = parseASCIIInteger(bytes, as: Int32.self) else {
                throw postgresDecodeError("Int32", oid: oid, format: format, bytes)
            }
            return value
        }
    }
}

extension Int64: PostgresDecodable {
    public static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> Int64 {
        switch format {
        case .binary:
            guard bytes.count == 8 else { throw postgresDecodeError("Int64", oid: oid, format: format, bytes) }
            return Int64(bitPattern: WireBinary.uint64(bytes))
        case .text:
            guard let value = parseASCIIInteger(bytes, as: Int64.self) else {
                throw postgresDecodeError("Int64", oid: oid, format: format, bytes)
            }
            return value
        }
    }
}

extension Int: PostgresDecodable {
    public static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> Int {
        switch format {
        case .binary:
            // Accept int2/int4/int8 by width.
            switch bytes.count {
            case 8: return Int(Int64(bitPattern: WireBinary.uint64(bytes)))
            case 4: return Int(Int32(bitPattern: WireBinary.uint32(bytes)))
            case 2: return Int(Int16(bitPattern: WireBinary.uint16(bytes)))
            default: throw postgresDecodeError("Int", oid: oid, format: format, bytes)
            }
        case .text:
            guard let value = parseASCIIInteger(bytes, as: Int.self) else {
                throw postgresDecodeError("Int", oid: oid, format: format, bytes)
            }
            return value
        }
    }
}

extension Float: PostgresDecodable {
    public static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> Float {
        switch format {
        case .binary:
            guard bytes.count == 4 else { throw postgresDecodeError("Float", oid: oid, format: format, bytes) }
            return Float(bitPattern: WireBinary.uint32(bytes))
        case .text:
            guard let value = parseASCIIFloatingPoint(bytes).map(Float.init) else {
                throw postgresDecodeError("Float", oid: oid, format: format, bytes)
            }
            return value
        }
    }
}

extension Double: PostgresDecodable {
    public static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> Double {
        switch format {
        case .binary:
            guard bytes.count == 8 else { throw postgresDecodeError("Double", oid: oid, format: format, bytes) }
            return Double(bitPattern: WireBinary.uint64(bytes))
        case .text:
            guard let value = parseASCIIFloatingPoint(bytes) else {
                throw postgresDecodeError("Double", oid: oid, format: format, bytes)
            }
            return value
        }
    }
}

extension String: PostgresDecodable {
    public static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> String {
        // jsonb's binary format is a 1-byte version header (0x01) then JSON text.
        if oid == PostgresOID.jsonb, format == .binary {
            guard let first = bytes.first, first == 1 else {
                throw postgresDecodeError("String(jsonb)", oid: oid, format: format, bytes)
            }
            return String(decoding: bytes.dropFirst(), as: UTF8.self)
        }
        return utf8String(bytes)
    }
}

extension Array: PostgresDecodable where Element == UInt8 {
    /// `bytea`: binary is the raw bytes; text is the `\x…` hex encoding.
    public static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> [UInt8] {
        switch format {
        case .binary:
            return bytes
        case .text:
            // Default bytea_output is hex: a leading "\x" then hex digits.
            if bytes.count >= 2, bytes[0] == 0x5c, bytes[1] == 0x78 {
                guard let decoded = decodeHex(Array(bytes.dropFirst(2))) else {
                    throw postgresDecodeError("[UInt8]", oid: oid, format: format, bytes)
                }
                return decoded
            }
            throw postgresDecodeError("[UInt8]", oid: oid, format: format, bytes)
        }
    }
}

private func decodeHex(_ ascii: [UInt8]) -> [UInt8]? {
    guard ascii.count % 2 == 0 else { return nil }
    func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30 ... 0x39: return c - 0x30            // 0-9
        case 0x61 ... 0x66: return c - 0x61 + 10       // a-f
        case 0x41 ... 0x46: return c - 0x41 + 10       // A-F
        default: return nil
        }
    }
    var out = [UInt8]()
    out.reserveCapacity(ascii.count / 2)
    var i = 0
    while i < ascii.count {
        guard let hi = nibble(ascii[i]), let lo = nibble(ascii[i + 1]) else { return nil }
        out.append((hi << 4) | lo)
        i += 2
    }
    return out
}

private protocol ASCIIInteger: FixedWidthInteger, SignedInteger {}
extension Int: ASCIIInteger {}
extension Int16: ASCIIInteger {}
extension Int32: ASCIIInteger {}
extension Int64: ASCIIInteger {}

private func parseASCIIInteger<T: ASCIIInteger>(_ bytes: [UInt8], as type: T.Type) -> T? {
    guard !bytes.isEmpty else { return nil }

    var index = 0
    let negative: Bool
    switch bytes[index] {
    case UInt8(ascii: "-"):
        negative = true
        index += 1
    case UInt8(ascii: "+"):
        negative = false
        index += 1
    default:
        negative = false
    }
    guard index < bytes.count else { return nil }

    var value = T.zero
    while index < bytes.count {
        let byte = bytes[index]
        guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
        let digit = T(byte - UInt8(ascii: "0"))
        let multiplied = value.multipliedReportingOverflow(by: 10)
        guard !multiplied.overflow else { return nil }
        let next = negative
            ? multiplied.partialValue.subtractingReportingOverflow(digit)
            : multiplied.partialValue.addingReportingOverflow(digit)
        guard !next.overflow else { return nil }
        value = next.partialValue
        index += 1
    }
    return value
}

private func parseASCIIFloatingPoint(_ bytes: [UInt8]) -> Double? {
    guard !bytes.isEmpty else { return nil }

    var index = 0
    var sign = 1.0
    switch bytes[index] {
    case UInt8(ascii: "-"):
        sign = -1.0
        index += 1
    case UInt8(ascii: "+"):
        index += 1
    default:
        break
    }
    guard index < bytes.count else { return nil }

    let remaining = bytes[index...]
    if asciiEqualsIgnoringCase(remaining, "nan") {
        return Double.nan
    }
    if asciiEqualsIgnoringCase(remaining, "inf") || asciiEqualsIgnoringCase(remaining, "infinity") {
        return sign * Double.infinity
    }

    var value = 0.0
    var digitCount = 0
    while index < bytes.count, let digit = decimalDigit(bytes[index]) {
        value = value * 10.0 + Double(digit)
        digitCount += 1
        index += 1
    }

    if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
        index += 1
        var divisor = 10.0
        while index < bytes.count, let digit = decimalDigit(bytes[index]) {
            value += Double(digit) / divisor
            divisor *= 10.0
            digitCount += 1
            index += 1
        }
    }

    guard digitCount > 0 else { return nil }

    if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
        index += 1
        guard let exponent = parseASCIIExponent(bytes, index: &index) else { return nil }
        value *= pow(10.0, Double(exponent))
    }

    guard index == bytes.count else { return nil }
    return sign * value
}

private func parseASCIIExponent(_ bytes: [UInt8], index: inout Int) -> Int? {
    guard index < bytes.count else { return nil }

    var negative = false
    switch bytes[index] {
    case UInt8(ascii: "-"):
        negative = true
        index += 1
    case UInt8(ascii: "+"):
        index += 1
    default:
        break
    }
    guard index < bytes.count else { return nil }

    var value = 0
    var hasDigit = false
    while index < bytes.count, let digit = decimalDigit(bytes[index]) {
        hasDigit = true
        let next = value.multipliedReportingOverflow(by: 10)
        guard !next.overflow else { return nil }
        let added = next.partialValue.addingReportingOverflow(Int(digit))
        guard !added.overflow else { return nil }
        value = added.partialValue
        index += 1
    }
    guard hasDigit else { return nil }
    return negative ? -value : value
}

private func decimalDigit(_ byte: UInt8) -> UInt8? {
    guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
    return byte - UInt8(ascii: "0")
}

private func asciiEqualsIgnoringCase(_ bytes: ArraySlice<UInt8>, _ string: String) -> Bool {
    let pattern = Array(string.utf8)
    guard bytes.count == pattern.count else { return false }
    for (byte, expected) in zip(bytes, pattern) {
        let folded = byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte
        if folded != expected { return false }
    }
    return true
}
