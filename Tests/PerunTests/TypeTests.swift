import XCTest
import Foundation
@testable import PerunPGSQL

/// Decoder correctness for both wire formats, on hand-built byte vectors.
final class TypeTests: XCTestCase {

    // MARK: Integers

    func testIntBinaryAndText() throws {
        // int4 = 42
        XCTAssertEqual(try Int.decode([0, 0, 0, 42], oid: PostgresOID.int4, format: .binary), 42)
        XCTAssertEqual(try Int.decode(Array("42".utf8), oid: PostgresOID.int4, format: .text), 42)
        XCTAssertEqual(try Int16.decode(Array("-32768".utf8), oid: PostgresOID.int2, format: .text), -32768)
        XCTAssertEqual(try Int32.decode(Array("+2147483647".utf8), oid: PostgresOID.int4, format: .text),
                       2147483647)
        // int8 = -1  → 0xFFFF_FFFF_FFFF_FFFF
        XCTAssertEqual(
            try Int64.decode([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
                             oid: PostgresOID.int8, format: .binary), -1)
        // int2 = 258 = 0x0102
        XCTAssertEqual(try Int16.decode([0x01, 0x02], oid: PostgresOID.int2, format: .binary), 258)
    }

    func testIntTextRejectsInvalidAndOverflow() {
        XCTAssertThrowsError(try Int16.decode(Array("32768".utf8), oid: PostgresOID.int2, format: .text))
        XCTAssertThrowsError(try Int32.decode(Array("12x".utf8), oid: PostgresOID.int4, format: .text))
        XCTAssertThrowsError(try Int64.decode(Array("-9223372036854775809".utf8),
                                              oid: PostgresOID.int8,
                                              format: .text))
    }

    func testDecodeErrorDoesNotExposeRawBytesByDefault() {
        XCTAssertThrowsError(try Int.decode(Array("secret-token".utf8),
                                            oid: PostgresOID.int4,
                                            format: .text)) { error in
            let description = String(describing: error)
            XCTAssertTrue(description.contains("12 bytes"))
            XCTAssertFalse(description.contains("secret-token"))
            XCTAssertFalse(description.contains("7365637265742d746f6b656e"))
        }
    }

    // MARK: Floating point

    func testDoubleBinaryRoundTrip() throws {
        var bits = UInt64(3.5.bitPattern).bigEndian
        let bytes = withUnsafeBytes(of: &bits) { Array($0) }
        XCTAssertEqual(try Double.decode(bytes, oid: PostgresOID.float8, format: .binary), 3.5)
        XCTAssertEqual(try Double.decode(Array("3.5".utf8), oid: PostgresOID.float8, format: .text), 3.5)
        XCTAssertEqual(try Double.decode(Array("-1.25e2".utf8), oid: PostgresOID.float8, format: .text), -125)
        XCTAssertEqual(try Float.decode(Array("+6.5E-1".utf8), oid: PostgresOID.float4, format: .text), 0.65)
        XCTAssertTrue(try Double.decode(Array("NaN".utf8), oid: PostgresOID.float8, format: .text).isNaN)
        XCTAssertEqual(try Double.decode(Array("-Infinity".utf8), oid: PostgresOID.float8, format: .text),
                       -Double.infinity)
    }

    func testFloatTextRejectsInvalidInput() {
        XCTAssertThrowsError(try Double.decode(Array("1.2.3".utf8), oid: PostgresOID.float8, format: .text))
        XCTAssertThrowsError(try Double.decode(Array("1e".utf8), oid: PostgresOID.float8, format: .text))
    }

    // Binary numeric decoders must check the column OID, not just the byte width, so a
    // same-width wrong type is rejected instead of having its bits reinterpreted.
    func testBinaryNumericDecodersRejectMismatchedOID() {
        // int4 bits decoded as Float would be 1.4e-45; must throw.
        XCTAssertThrowsError(try Float.decode([0x00, 0x00, 0x00, 0x01], oid: PostgresOID.int4, format: .binary))
        // float8 bits decoded as Int64 would be garbage; must throw.
        let onePointFive = withUnsafeBytes(of: UInt64(1.5.bitPattern).bigEndian) { Array($0) }
        XCTAssertThrowsError(try Int64.decode(onePointFive, oid: PostgresOID.float8, format: .binary))
        XCTAssertThrowsError(try Int.decode(onePointFive, oid: PostgresOID.float8, format: .binary))
        // float4 decoded as Int32 (both 4 bytes) must throw.
        XCTAssertThrowsError(try Int32.decode([0x3F, 0xC0, 0x00, 0x00], oid: PostgresOID.float4, format: .binary))
        // Matching OIDs still decode.
        XCTAssertEqual(try Int32.decode([0x00, 0x00, 0x00, 0x2A], oid: PostgresOID.int4, format: .binary), 42)
        XCTAssertEqual(try Int.decode([0x00, 0x00, 0x00, 0x2A], oid: PostgresOID.int4, format: .binary), 42)
    }

    // Regression: PostgreSQL prints the shortest float text that round-trips, so a
    // correctly-rounded parse must return the exact same bits. Several of these were
    // mis-parsed (off by 1–3 ULP) by the previous accumulate-and-pow(10,e) parser.
    func testFloatTextRoundTripsExactly() throws {
        let doubles: [Double] = [
            0.1, 0.2, 0.3, 1.0 / 3.0, 2.0 / 3.0, .pi, -0.0,
            123456789.123456789, 8.98846567431158e307,
            1.1011887870356423e-09, -3.5142406180792793e257,
        ]
        for d in doubles {
            let decoded = try Double.decode(Array(String(d).utf8), oid: PostgresOID.float8, format: .text)
            XCTAssertEqual(decoded.bitPattern, d.bitPattern, "Double round-trip failed for \(d)")
        }

        let floats: [Float] = [0.1, 0.2, 1.0 / 3.0, .pi, 3.4028235e38, 1.175_494_4e-38]
        for f in floats {
            let decoded = try Float.decode(Array(String(f).utf8), oid: PostgresOID.float4, format: .text)
            XCTAssertEqual(decoded.bitPattern, f.bitPattern, "Float round-trip failed for \(f)")
        }

        XCTAssertTrue(try Double.decode(Array("NaN".utf8), oid: PostgresOID.float8, format: .text).isNaN)
        XCTAssertEqual(try Double.decode(Array("Infinity".utf8), oid: PostgresOID.float8, format: .text), .infinity)
        XCTAssertEqual(try Double.decode(Array("-Infinity".utf8), oid: PostgresOID.float8, format: .text), -.infinity)
    }

    // MARK: Bool

    func testBool() throws {
        XCTAssertTrue(try Bool.decode([1], oid: PostgresOID.bool, format: .binary))
        XCTAssertFalse(try Bool.decode([0], oid: PostgresOID.bool, format: .binary))
        XCTAssertTrue(try Bool.decode(Array("t".utf8), oid: PostgresOID.bool, format: .text))
        XCTAssertFalse(try Bool.decode(Array("false".utf8), oid: PostgresOID.bool, format: .text))
    }

    // MARK: UUID

    func testUUID() throws {
        let bytes: [UInt8] = [0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
                              0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00]
        let expected = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
        XCTAssertEqual(try UUID.decode(bytes, oid: PostgresOID.uuid, format: .binary), expected)
        XCTAssertEqual(try UUID.decode(Array("550e8400-e29b-41d4-a716-446655440000".utf8),
                                       oid: PostgresOID.uuid, format: .text), expected)
    }

    // MARK: bytea

    func testByteaHexText() throws {
        XCTAssertEqual(try [UInt8].decode(Array("\\xdeadbeef".utf8),
                                          oid: PostgresOID.bytea, format: .text),
                       [0xde, 0xad, 0xbe, 0xef])
        XCTAssertEqual(try [UInt8].decode([0xde, 0xad, 0xbe, 0xef],
                                          oid: PostgresOID.bytea, format: .binary),
                       [0xde, 0xad, 0xbe, 0xef])
    }

    // MARK: Temporal — text and binary must agree

    func testTimestampTextAndBinaryAgree() throws {
        // 2000-01-01 00:00:00 UTC is PostgreSQL's epoch → micros = 0.
        let binaryEpoch = try Date.decode([0, 0, 0, 0, 0, 0, 0, 0],
                                          oid: PostgresOID.timestamptz, format: .binary)
        XCTAssertEqual(binaryEpoch.timeIntervalSince1970, 946_684_800, accuracy: 0.0001)

        let textEpoch = try Date.decode(Array("2000-01-01 00:00:00+00".utf8),
                                        oid: PostgresOID.timestamptz, format: .text)
        XCTAssertEqual(textEpoch.timeIntervalSince1970, 946_684_800, accuracy: 0.0001)

        // A date: 2026-07-07.
        let textDate = try Date.decode(Array("2026-07-07".utf8), oid: PostgresOID.date, format: .text)
        XCTAssertEqual(textDate.timeIntervalSince1970, 1_783_382_400, accuracy: 0.0001)
    }

    func testTimestampTextAllowsLargeYears() throws {
        let value = try Date.decode(Array("12345-01-01".utf8), oid: PostgresOID.timestamp, format: .text)
        XCTAssertEqual(value.timeIntervalSince1970,
                       Self.dateFromCivil(year: 12345, month: 1, day: 1).timeIntervalSince1970,
                       accuracy: 0.0001)
    }

    func testTimestampTextHandlesBCEra() throws {
        let dateOnly = try Date.decode(Array("0044-03-15 BC".utf8), oid: PostgresOID.timestamp, format: .text)
        XCTAssertEqual(dateOnly.timeIntervalSince1970,
                       Self.dateFromCivil(year: -43, month: 3, day: 15).timeIntervalSince1970,
                       accuracy: 0.0001)

        let timestamp = try Date.decode(Array("0044-03-15 12:30:00 BC".utf8),
                                        oid: PostgresOID.timestamp,
                                        format: .text)
        XCTAssertEqual(timestamp.timeIntervalSince1970,
                       Self.dateFromCivil(year: -43, month: 3, day: 15,
                                          hour: 12, minute: 30).timeIntervalSince1970,
                       accuracy: 0.0001)
    }

    func testTimestampTextRejectsTrailingJunk() {
        XCTAssertThrowsError(try Date.decode(Array("2026-07-07 surprise".utf8),
                                             oid: PostgresOID.timestamp,
                                             format: .text))
    }

    func testTimestampInfinityTextAndBinaryAgree() throws {
        // Binary ±infinity are the Int64 extremes; text renders them literally. Both must map
        // to Date's distant sentinels, never a finite date fabricated from the sentinel bits.
        let binaryPosInf = try Date.decode([0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
                                           oid: PostgresOID.timestamptz, format: .binary)
        let binaryNegInf = try Date.decode([0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
                                           oid: PostgresOID.timestamptz, format: .binary)
        XCTAssertEqual(binaryPosInf, .distantFuture)
        XCTAssertEqual(binaryNegInf, .distantPast)

        XCTAssertEqual(try Date.decode(Array("infinity".utf8), oid: PostgresOID.timestamptz, format: .text),
                       .distantFuture)
        XCTAssertEqual(try Date.decode(Array("-infinity".utf8), oid: PostgresOID.timestamptz, format: .text),
                       .distantPast)

        // date 'infinity' / '-infinity' are the Int32 extremes.
        XCTAssertEqual(try Date.decode([0x7F, 0xFF, 0xFF, 0xFF], oid: PostgresOID.date, format: .binary),
                       .distantFuture)
        XCTAssertEqual(try Date.decode([0x80, 0x00, 0x00, 0x00], oid: PostgresOID.date, format: .binary),
                       .distantPast)
    }

    // MARK: numeric — binary base-10000 groups

    func testNumericBinary() throws {
        // 1234.56 → ndigits 2, weight 0, sign +, dscale 2, digits [1234, 5600].
        let bytes: [UInt8] = [
            0x00, 0x02,             // ndigits
            0x00, 0x00,             // weight
            0x00, 0x00,             // sign +
            0x00, 0x02,             // dscale
            0x04, 0xD2,             // 1234
            0x15, 0xE0,             // 5600
        ]
        XCTAssertEqual(try Decimal.decode(bytes, oid: PostgresOID.numeric, format: .binary),
                       Decimal(string: "1234.56"))
        XCTAssertEqual(try Decimal.decode(Array("1234.56".utf8),
                                          oid: PostgresOID.numeric, format: .text),
                       Decimal(string: "1234.56"))
    }

    func testNumericBinaryRejectsNegativeDigitCount() {
        let bytes: [UInt8] = [
            0xFF, 0xFF,             // ndigits = -1
            0x00, 0x00,             // weight
            0x00, 0x00,             // sign +
            0x00, 0x00,             // dscale
        ]
        XCTAssertThrowsError(try Decimal.decode(bytes, oid: PostgresOID.numeric, format: .binary)) { error in
            guard case PerunError.decodingFailed = error else {
                return XCTFail("expected .decodingFailed, got \(error)")
            }
        }
    }

    func testNumericBinaryRejectsOutOfRangePositiveExponent() {
        let bytes: [UInt8] = [
            0x00, 0x01,             // ndigits
            0x00, 0x20,             // weight = 32 -> exponent 128
            0x00, 0x00,             // sign +
            0x00, 0x00,             // dscale
            0x00, 0x01,             // digit 1
        ]
        XCTAssertThrowsError(try Decimal.decode(bytes, oid: PostgresOID.numeric, format: .binary)) { error in
            guard case PerunError.decodingFailed = error else {
                return XCTFail("expected .decodingFailed, got \(error)")
            }
        }
    }

    func testNumericBinaryRejectsOutOfRangeNegativeExponent() {
        let bytes: [UInt8] = [
            0x00, 0x01,             // ndigits
            0xFF, 0xDF,             // weight = -33 -> exponent -132
            0x00, 0x00,             // sign +
            0x00, 0x00,             // dscale
            0x00, 0x01,             // digit 1
        ]
        XCTAssertThrowsError(try Decimal.decode(bytes, oid: PostgresOID.numeric, format: .binary)) { error in
            guard case PerunError.decodingFailed = error else {
                return XCTFail("expected .decodingFailed, got \(error)")
            }
        }
    }

    // MARK: jsonb strips its binary version header

    func testJSONBBinaryHeader() throws {
        let json = "{\"a\":1}"
        let bytes: [UInt8] = [0x01] + Array(json.utf8)
        XCTAssertEqual(try String.decode(bytes, oid: PostgresOID.jsonb, format: .binary), json)
    }

    private static func dateFromCivil(year: Int,
                                      month: Int,
                                      day: Int,
                                      hour: Int = 0,
                                      minute: Int = 0,
                                      second: Int = 0) -> Date {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let epochSeconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second)
        return Date(timeIntervalSince1970: epochSeconds)
    }
}
