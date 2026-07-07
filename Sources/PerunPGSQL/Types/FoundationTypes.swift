import Foundation

// Decoders for common Foundation value types. This is the only part of the
// driver that leans on Foundation; the wire / crypto / socket core stays free of
// it. These are the natural Swift representations for uuid, bytea, the temporal
// types and numeric.

extension Data: PostgresDecodable {
    public static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> Data {
        Data(try [UInt8].decode(bytes, oid: oid, format: format))
    }
}

extension UUID: PostgresDecodable {
    public static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> UUID {
        switch format {
        case .binary:
            guard bytes.count == 16 else { throw postgresDecodeError("UUID", oid: oid, format: format, bytes) }
            return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                               bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11],
                               bytes[12], bytes[13], bytes[14], bytes[15]))
        case .text:
            guard let uuid = UUID(uuidString: utf8String(bytes)) else {
                throw postgresDecodeError("UUID", oid: oid, format: format, bytes)
            }
            return uuid
        }
    }
}

extension Date: PostgresDecodable {
    /// Seconds between Swift's reference date (2001-01-01) and PostgreSQL's
    /// epoch (2000-01-01). 2000 is a leap year → 366 days.
    private static let pgEpochToReferenceDate: TimeInterval = 31_622_400

    public static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> Date {
        switch format {
        case .binary:
            switch oid {
            case PostgresOID.timestamp, PostgresOID.timestamptz:
                guard bytes.count == 8 else { throw postgresDecodeError("Date", oid: oid, format: format, bytes) }
                let microseconds = Int64(bitPattern: WireBinary.uint64(bytes))
                let seconds = Double(microseconds) / 1_000_000
                return Date(timeIntervalSinceReferenceDate: seconds - pgEpochToReferenceDate)
            case PostgresOID.date:
                guard bytes.count == 4 else { throw postgresDecodeError("Date", oid: oid, format: format, bytes) }
                let days = Int32(bitPattern: WireBinary.uint32(bytes))
                return Date(timeIntervalSinceReferenceDate: Double(days) * 86_400 - pgEpochToReferenceDate)
            default:
                throw postgresDecodeError("Date", oid: oid, format: format, bytes)
            }
        case .text:
            guard let date = parsePostgresTimestamp(utf8String(bytes)) else {
                throw postgresDecodeError("Date", oid: oid, format: format, bytes)
            }
            return date
        }
    }
}

extension Decimal: PostgresDecodable {
    public static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> Decimal {
        switch format {
        case .text:
            guard let value = Decimal(string: utf8String(bytes)) else {
                throw postgresDecodeError("Decimal", oid: oid, format: format, bytes)
            }
            return value
        case .binary:
            return try decodeBinaryNumeric(bytes, oid: oid)
        }
    }

    /// PostgreSQL numeric binary layout: int16 ndigits, int16 weight, uint16
    /// sign, int16 dscale, then `ndigits` base-10000 groups. The value is
    /// Σ digit[i] · 10000^(weight − i).
    private static func decodeBinaryNumeric(_ bytes: [UInt8], oid: Int32) throws -> Decimal {
        var reader = ByteReader(bytes)
        let digitCount = Int(try reader.readInt16())
        let weight = Int(try reader.readInt16())
        let sign = UInt16(bitPattern: try reader.readInt16())
        _ = try reader.readInt16()                          // dscale — display only

        guard digitCount >= 0 else {
            throw postgresDecodeError("Decimal", oid: oid, format: .binary, bytes)
        }
        guard sign == 0x0000 || sign == 0x4000 else {
            // 0xC000 = NaN, 0xD000/0xF000 = ±infinity — not representable as Decimal.
            throw postgresDecodeError("Decimal", oid: oid, format: .binary, bytes)
        }

        var value = Decimal(0)
        for i in 0 ..< digitCount {
            let digit = Int(try reader.readInt16())         // 0…9999
            let exponent = 4 * (weight - i)                 // 10000^(weight-i) = 10^(4·…)
            guard digit >= 0, digit <= 9999 else {
                throw postgresDecodeError("Decimal", oid: oid, format: .binary, bytes)
            }
            guard digit == 0 || (-128 ... 127).contains(exponent) else {
                throw postgresDecodeError("Decimal", oid: oid, format: .binary, bytes)
            }
            let term = Decimal(sign: .plus, exponent: exponent, significand: Decimal(digit))
            guard !term.isNaN else {
                throw postgresDecodeError("Decimal", oid: oid, format: .binary, bytes)
            }
            value += term
            guard !value.isNaN else {
                throw postgresDecodeError("Decimal", oid: oid, format: .binary, bytes)
            }
        }
        return sign == 0x4000 ? -value : value
    }
}

// MARK: - Text timestamp parsing

/// Parse PostgreSQL's default text rendering of `date` / `timestamp` /
/// `timestamptz`, e.g. `2026-07-07`, `2026-07-07 20:50:24.123456`, or
/// `2026-07-07 20:50:24.123456+00`. Returns nil if it doesn't match.
func parsePostgresTimestamp(_ string: String) -> Date? {
    let scalars = Array(string.utf8)
    var index = 0

    func readInt(maxDigits: Int) -> Int? {
        var value = 0
        var count = 0
        while index < scalars.count, scalars[index] >= 0x30, scalars[index] <= 0x39, count < maxDigits {
            value = value * 10 + Int(scalars[index] - 0x30)
            index += 1
            count += 1
        }
        return count > 0 ? value : nil
    }
    func expect(_ ascii: UInt8) -> Bool {
        guard index < scalars.count, scalars[index] == ascii else { return false }
        index += 1
        return true
    }
    func isDigit(_ ascii: UInt8) -> Bool {
        ascii >= 0x30 && ascii <= 0x39
    }

    guard var year = readInt(maxDigits: 9), expect(0x2d),          // '-'
          let month = readInt(maxDigits: 2), expect(0x2d),
          let day = readInt(maxDigits: 2) else { return nil }

    var hour = 0, minute = 0, second = 0
    var fractional = 0.0
    var offsetSeconds = 0

    // Optional time part, after a space or 'T'.
    if index < scalars.count,
       scalars[index] == 0x54
        || (scalars[index] == 0x20 && index + 1 < scalars.count && isDigit(scalars[index + 1])) {
        index += 1
        guard let h = readInt(maxDigits: 2), expect(0x3a),          // ':'
              let m = readInt(maxDigits: 2), expect(0x3a),
              let s = readInt(maxDigits: 2) else { return nil }
        hour = h; minute = m; second = s

        if expect(0x2e) {                                           // '.frac'
            let start = index
            guard let frac = readInt(maxDigits: 9) else { return nil }
            let digits = index - start
            fractional = Double(frac) / pow(10.0, Double(digits))
        }

        // Optional timezone offset: ±HH[:MM[:SS]] or 'Z'.
        if index < scalars.count, scalars[index] == 0x2b || scalars[index] == 0x2d {
            let negative = scalars[index] == 0x2d
            index += 1
            guard let oh = readInt(maxDigits: 2) else { return nil }
            var om = 0, os = 0
            if expect(0x3a) { om = readInt(maxDigits: 2) ?? 0 }
            if expect(0x3a) { os = readInt(maxDigits: 2) ?? 0 }
            let magnitude = oh * 3600 + om * 60 + os
            offsetSeconds = negative ? -magnitude : magnitude
        } else if index < scalars.count, scalars[index] == 0x5a {  // 'Z'
            index += 1
        }
    }

    if index < scalars.count {
        guard expect(0x20) else { return nil }                     // ' '
        if index + 1 < scalars.count, scalars[index] == 0x42, scalars[index + 1] == 0x43 {
            year = 1 - year                                        // PostgreSQL has no year zero.
            index += 2
        } else if index + 1 < scalars.count, scalars[index] == 0x41, scalars[index + 1] == 0x44 {
            index += 2
        } else {
            return nil
        }
    }
    guard index == scalars.count else { return nil }

    let days = daysFromCivil(year: year, month: month, day: day)
    let epochSeconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second)
        + fractional - Double(offsetSeconds)
    return Date(timeIntervalSince1970: epochSeconds)
}

/// Days from the Unix epoch (1970-01-01) to the given proleptic Gregorian date.
/// Howard Hinnant's `days_from_civil` algorithm.
private func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yearOfEra = y - era * 400                                   // [0, 399]
    let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
}
