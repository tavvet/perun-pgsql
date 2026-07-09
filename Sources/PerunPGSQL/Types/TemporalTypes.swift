// Codecs for the temporal types PostgreSQL can't map onto a Foundation value:
// `interval` (months/days/microseconds — a month isn't a fixed number of seconds, so it
// can't collapse to a `Date` offset) and `time` (a time of day with no date). Both decode
// and encode in text and binary. `timetz` is left as text-decodable (see the roadmap).

/// A PostgreSQL `interval`: independent month, day, and microsecond components, matching the
/// server's own representation. Months and days are kept apart from microseconds because
/// their length in time depends on the calendar (months vary; a day varies across DST).
public struct PostgresInterval: Sendable, Equatable {
    public var months: Int32
    public var days: Int32
    public var microseconds: Int64

    public init(months: Int32 = 0, days: Int32 = 0, microseconds: Int64 = 0) {
        self.months = months
        self.days = days
        self.microseconds = microseconds
    }
}

/// A PostgreSQL `time` (time of day, no date), as microseconds since midnight.
public struct PostgresTime: Sendable, Equatable {
    /// Microseconds since midnight, `0 ..< 86_400_000_000` (24:00:00 is also valid).
    public var microseconds: Int64

    public init(microseconds: Int64) {
        self.microseconds = microseconds
    }

    public init(hour: Int, minute: Int, second: Int, microsecond: Int = 0) {
        self.microseconds = ((Int64(hour) * 60 + Int64(minute)) * 60 + Int64(second)) * 1_000_000
            + Int64(microsecond)
    }
}

/// A PostgreSQL `timetz` (time of day with a UTC offset). `zoneOffsetSeconds` is east of UTC
/// in the usual sense (`+05:00` → `18_000`), the negation of PostgreSQL's internal "seconds
/// west" representation.
public struct PostgresTimeTz: Sendable, Equatable {
    public var time: PostgresTime
    public var zoneOffsetSeconds: Int32

    public init(time: PostgresTime, zoneOffsetSeconds: Int32) {
        self.time = time
        self.zoneOffsetSeconds = zoneOffsetSeconds
    }
}

// MARK: - Decoding

extension PostgresInterval: PostgresDecodable {
    public static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> PostgresInterval {
        switch format {
        case .binary:
            // int64 microseconds, int32 days, int32 months.
            guard bytes.count == 16 else { throw postgresDecodeError("interval", oid: oid, format: format, bytes) }
            var reader = ByteReader(bytes)
            let microseconds = try reader.readInt64()
            let days = try reader.readInt32()
            let months = try reader.readInt32()
            return PostgresInterval(months: months, days: days, microseconds: microseconds)
        case .text:
            guard let interval = parsePostgresInterval(utf8String(bytes)) else {
                throw postgresDecodeError("interval", oid: oid, format: format, bytes)
            }
            return interval
        }
    }
}

extension PostgresTime: PostgresDecodable {
    public static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> PostgresTime {
        switch format {
        case .binary:
            guard bytes.count == 8 else { throw postgresDecodeError("time", oid: oid, format: format, bytes) }
            var reader = ByteReader(bytes)
            return PostgresTime(microseconds: try reader.readInt64())
        case .text:
            guard let micros = parseClockToMicroseconds(Substring(utf8String(bytes))) else {
                throw postgresDecodeError("time", oid: oid, format: format, bytes)
            }
            return PostgresTime(microseconds: micros)
        }
    }
}

extension PostgresTimeTz: PostgresDecodable {
    public static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> PostgresTimeTz {
        switch format {
        case .binary:
            // int64 microseconds, int32 zone (seconds *west* of UTC).
            guard bytes.count == 12 else { throw postgresDecodeError("timetz", oid: oid, format: format, bytes) }
            var reader = ByteReader(bytes)
            let microseconds = try reader.readInt64()
            let zoneWest = try reader.readInt32()
            return PostgresTimeTz(time: PostgresTime(microseconds: microseconds), zoneOffsetSeconds: -zoneWest)
        case .text:
            guard let value = parsePostgresTimeTz(utf8String(bytes)) else {
                throw postgresDecodeError("timetz", oid: oid, format: format, bytes)
            }
            return value
        }
    }
}

// Arrays of these types decode through the recursive `decodeArray` path.
extension PostgresInterval: PostgresArrayDecodable { public typealias ArrayScalar = PostgresInterval }
extension PostgresTime: PostgresArrayDecodable { public typealias ArrayScalar = PostgresTime }
extension PostgresTimeTz: PostgresArrayDecodable { public typealias ArrayScalar = PostgresTimeTz }

// MARK: - Encoding

extension PostgresInterval: PostgresEncodable {
    /// Months, days and seconds sent as explicit units, so nothing is lost collapsing a
    /// month to seconds. PostgreSQL parses e.g. `3 mons 2 days 5.500000 secs`.
    public var postgresText: String? {
        let magnitude = microseconds.magnitude                     // avoids Int64.min overflow
        let sign = microseconds < 0 ? "-" : ""
        let seconds = "\(sign)\(magnitude / 1_000_000).\(pad(magnitude % 1_000_000, to: 6))"
        return "\(months) mons \(days) days \(seconds) secs"
    }

    public var postgresTypeOID: Int32 { PostgresOID.interval }

    public func postgresBinary() -> [UInt8]? {
        bigEndianBytes(microseconds) + bigEndianBytes(days) + bigEndianBytes(months)
    }
}

extension PostgresTime: PostgresEncodable {
    public var postgresText: String? {
        let m = microseconds
        return "\(pad(m / 3_600_000_000, to: 2)):\(pad((m / 60_000_000) % 60, to: 2))"
            + ":\(pad((m / 1_000_000) % 60, to: 2)).\(pad(m % 1_000_000, to: 6))"
    }

    public var postgresTypeOID: Int32 { PostgresOID.time }

    public func postgresBinary() -> [UInt8]? { bigEndianBytes(microseconds) }
}

extension PostgresTimeTz: PostgresEncodable {
    public var postgresText: String? {
        let magnitude = zoneOffsetSeconds.magnitude
        let sign = zoneOffsetSeconds < 0 ? "-" : "+"
        var zone = "\(sign)\(pad(magnitude / 3600, to: 2)):\(pad((magnitude % 3600) / 60, to: 2))"
        if magnitude % 60 != 0 { zone += ":\(pad(magnitude % 60, to: 2))" }
        return (time.postgresText ?? "") + zone
    }

    public var postgresTypeOID: Int32 { PostgresOID.timetz }

    public func postgresBinary() -> [UInt8]? {
        bigEndianBytes(time.microseconds) + bigEndianBytes(-zoneOffsetSeconds)   // zone is seconds west of UTC
    }
}

// MARK: - Text parsing

/// Parse PostgreSQL's default (`intervalstyle = postgres`) interval text, e.g.
/// `1 year 2 mons 3 days 04:05:06.789`, `-1 days +02:03:04`, `00:00:01`, `2 mons`.
func parsePostgresInterval(_ text: String) -> PostgresInterval? {
    var months: Int64 = 0, days: Int64 = 0, microseconds: Int64 = 0
    let tokens = text.split(separator: " ", omittingEmptySubsequences: true)
    var index = 0
    while index < tokens.count {
        let token = tokens[index]
        if token.contains(":") {                                   // the HH:MM:SS[.ffffff] time part
            guard let micros = parseClockToMicroseconds(token) else { return nil }
            microseconds += micros
            index += 1
            continue
        }
        guard index + 1 < tokens.count, let value = Int64(token) else { return nil }
        switch tokens[index + 1] {
        case "year", "years":               months += value * 12
        case "mon", "mons", "month", "months": months += value
        case "day", "days":                 days += value
        case "hour", "hours":               microseconds += value * 3_600_000_000
        case "min", "mins", "minute", "minutes": microseconds += value * 60_000_000
        case "sec", "secs", "second", "seconds": microseconds += value * 1_000_000
        default:                            return nil
        }
        index += 2
    }
    guard let months32 = Int32(exactly: months), let days32 = Int32(exactly: days) else { return nil }
    return PostgresInterval(months: months32, days: days32, microseconds: microseconds)
}

/// Parse `HH:MM:SS[.ffffff]` (optionally signed) into microseconds. Hours may exceed 24 in
/// an interval; the fraction is padded/truncated to microseconds.
private func parseClockToMicroseconds(_ token: Substring) -> Int64? {
    var body = token
    var negative = false
    if body.first == "-" { negative = true; body = body.dropFirst() }
    else if body.first == "+" { body = body.dropFirst() }

    let parts = body.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, let hours = Int64(parts[0]), let minutes = Int64(parts[1]) else { return nil }

    let secondParts = parts[2].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard let seconds = Int64(secondParts[0]) else { return nil }

    var micros = ((hours * 60 + minutes) * 60 + seconds) * 1_000_000
    if secondParts.count == 2 {
        var scale: Int64 = 100_000
        for character in secondParts[1].prefix(6) {
            guard let digit = character.wholeNumberValue, (0 ... 9).contains(digit) else { return nil }
            micros += Int64(digit) * scale
            scale /= 10
        }
    }
    return negative ? -micros : micros
}

/// Parse `HH:MM:SS[.ffffff]±HH[:MM[:SS]]`, e.g. `12:34:56.789+05:30`. The time part never
/// carries a sign, so the first `+`/`-` starts the zone.
func parsePostgresTimeTz(_ text: String) -> PostgresTimeTz? {
    guard let signIndex = text.firstIndex(where: { $0 == "+" || $0 == "-" }),
          let micros = parseClockToMicroseconds(text[..<signIndex]) else { return nil }

    var zone = text[signIndex...]
    let negative = zone.first == "-"
    zone = zone.dropFirst()
    let parts = zone.split(separator: ":")
    guard let hoursText = parts.first, let hours = Int32(hoursText) else { return nil }
    let minutes = parts.count > 1 ? (Int32(parts[1]) ?? 0) : 0
    let seconds = parts.count > 2 ? (Int32(parts[2]) ?? 0) : 0
    let magnitude = hours * 3600 + minutes * 60 + seconds
    return PostgresTimeTz(time: PostgresTime(microseconds: micros),
                          zoneOffsetSeconds: negative ? -magnitude : magnitude)
}

/// Left-pad a non-negative integer with zeros to at least `width` digits.
private func pad(_ value: some BinaryInteger, to width: Int) -> String {
    var string = "\(value)"
    while string.count < width { string = "0" + string }
    return string
}
