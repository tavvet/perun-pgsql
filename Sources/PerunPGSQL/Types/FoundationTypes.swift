import Foundation

// Codecs for common Foundation value types: decoders for all of them, plus
// parameter encoders for UUID, Date, Data (bytea) and Decimal (numeric). This is
// the only part of the driver that leans on Foundation; the wire / crypto / socket
// core stays free of it. These are the natural Swift representations for uuid,
// bytea, the temporal types and numeric.

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
                // PostgreSQL encodes ±infinity as the Int64 extremes. `Date` can't hold infinity,
                // so map them to its distant sentinels (as the text path does) rather than
                // silently decode Int64.max µs into a finite date around year 294247.
                if microseconds == Int64.max { return .distantFuture }
                if microseconds == Int64.min { return .distantPast }
                let seconds = Double(microseconds) / 1_000_000
                return Date(timeIntervalSinceReferenceDate: seconds - pgEpochToReferenceDate)
            case PostgresOID.date:
                guard bytes.count == 4 else { throw postgresDecodeError("Date", oid: oid, format: format, bytes) }
                let days = Int32(bitPattern: WireBinary.uint32(bytes))
                if days == Int32.max { return .distantFuture }        // 'infinity'::date
                if days == Int32.min { return .distantPast }          // '-infinity'::date
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
    // PostgreSQL renders ±infinity literally; `Date` has no infinity, so use its sentinels
    // (the binary decoder maps Int64.max/min the same way).
    if string == "infinity" { return .distantFuture }
    if string == "-infinity" { return .distantPast }

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

// MARK: - Parameter encoding

extension UUID: PostgresEncodable {
    public var postgresText: String? { uuidString }
    public var postgresTypeOID: Int32 { PostgresOID.uuid }
    public func postgresBinary() -> [UInt8]? {
        let b = uuid
        return [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7,
                b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15]
    }
}

extension Date: PostgresEncodable {
    /// A `Date` is an instant, so it maps to `timestamptz`.
    public var postgresText: String? { postgresTimestampText(self) }
    public var postgresTypeOID: Int32 { PostgresOID.timestamptz }
    public func postgresBinary() -> [UInt8]? {
        // Microseconds since 2000-01-01 UTC (PostgreSQL's epoch), which is
        // 31_622_400 s after Swift's 2001-01-01 reference date. Big-endian int8.
        let secondsSinceEpoch = timeIntervalSinceReferenceDate + 31_622_400
        return bigEndianBytes(Int64((secondsSinceEpoch * 1_000_000).rounded()))
    }
}

extension Data: PostgresEncodable {
    public var postgresText: String? { "\\x" + hexEncode(Array(self)) }   // bytea hex input
    public var postgresTypeOID: Int32 { PostgresOID.bytea }
    public func postgresBinary() -> [UInt8]? { Array(self) }              // binary is the raw bytes
}

extension Decimal: PostgresEncodable {
    public var postgresText: String? { description }                     // plain decimal, e.g. "-12345.6789"
    public var postgresTypeOID: Int32 { PostgresOID.numeric }
    public func postgresBinary() -> [UInt8]? { postgresNumericBinary(description) }
}

/// Encode a plain decimal string (`Decimal.description`, e.g. `-12345.6789`) into
/// PostgreSQL's `numeric` binary form: int16 ndigits, int16 weight, uint16 sign,
/// int16 dscale, then `ndigits` base-10000 groups (value = Σ digit·10000^(weight−i)).
/// Returns nil for anything that isn't plain decimal digits — `NaN`, an exponent —
/// so the caller falls back to text, which PostgreSQL still parses. Inverse of
/// `Decimal.decodeBinaryNumeric`.
private func postgresNumericBinary(_ text: String) -> [UInt8]? {
    var body = Substring(text)
    var sign: UInt16 = 0x0000
    if body.first == "-" { sign = 0x4000; body = body.dropFirst() }
    else if body.first == "+" { body = body.dropFirst() }

    func asciiDigitValues(_ s: Substring) -> [UInt8]? {
        var values = [UInt8]()
        for byte in s.utf8 {
            guard byte >= 0x30, byte <= 0x39 else { return nil }         // digits only
            values.append(byte - 0x30)
        }
        return values
    }
    let halves = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard let intValues = asciiDigitValues(halves[0]),
          let fracValues = asciiDigitValues(halves.count == 2 ? halves[1] : "") else { return nil }
    let dscale = fracValues.count

    // Align to base-10000 groups: pad the integer part on the left and the fraction
    // on the right, so the decimal point falls on a group boundary.
    let intAligned = Array(repeating: UInt8(0), count: (4 - intValues.count % 4) % 4) + intValues
    let fracAligned = fracValues + Array(repeating: UInt8(0), count: (4 - fracValues.count % 4) % 4)
    let integerGroups = intAligned.count / 4

    var groups = [Int16]()
    let stream = intAligned + fracAligned
    var i = 0
    while i < stream.count {
        let value = Int(stream[i]) * 1000 + Int(stream[i + 1]) * 100
                  + Int(stream[i + 2]) * 10 + Int(stream[i + 3])
        groups.append(Int16(value))
        i += 4
    }

    var weight = integerGroups - 1
    while groups.first == 0 { groups.removeFirst(); weight -= 1 }         // leading zero groups shift the point
    while groups.last == 0 { groups.removeLast() }                        // trailing zero groups are implicit
    if groups.isEmpty { weight = 0; sign = 0x0000 }                       // canonical zero

    var out = [UInt8]()
    out += bigEndianBytes(Int16(groups.count))
    out += bigEndianBytes(Int16(weight))
    out += bigEndianBytes(sign)
    out += bigEndianBytes(Int16(dscale))
    for group in groups { out += bigEndianBytes(group) }
    return out
}

/// Render a `Date` as PostgreSQL `timestamptz` text at UTC, microsecond precision:
/// `YYYY-MM-DD HH:MM:SS.ffffff+00`. (Used for the text parameter path; binary is exact.)
private func postgresTimestampText(_ date: Date) -> String {
    let totalMicros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    var seconds = totalMicros / 1_000_000
    var micros = totalMicros - seconds * 1_000_000
    if micros < 0 { micros += 1_000_000; seconds -= 1 }        // floor toward negative infinity
    let days = Int((Double(seconds) / 86_400).rounded(.down))
    let secondOfDay = Int(seconds - Int64(days) * 86_400)
    let (year, month, day) = civilFromDays(days)
    let displayYear = year <= 0 ? 1 - year : year               // no year zero: 0 → 1 BC
    let eraSuffix = year <= 0 ? " BC" : ""
    return String(format: "%04d-%02d-%02d %02d:%02d:%02d.%06d+00",
                  displayYear, month, day,
                  secondOfDay / 3600, (secondOfDay % 3600) / 60, secondOfDay % 60,
                  Int(micros)) + eraSuffix
}

/// Inverse of `daysFromCivil`: the proleptic Gregorian date for a day count since
/// 1970-01-01. Howard Hinnant's `civil_from_days`.
private func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let dayOfEra = z - era * 146_097                                              // [0, 146096]
    let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let year = yearOfEra + era * 400
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)  // [0, 365]
    let monthPortion = (5 * dayOfYear + 2) / 153                                  // [0, 11]
    let day = dayOfYear - (153 * monthPortion + 2) / 5 + 1                        // [1, 31]
    let month = monthPortion < 10 ? monthPortion + 3 : monthPortion - 9          // [1, 12]
    return (month <= 2 ? year + 1 : year, month, day)
}
