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
        // int8 = -1  → 0xFFFF_FFFF_FFFF_FFFF
        XCTAssertEqual(
            try Int64.decode([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
                             oid: PostgresOID.int8, format: .binary), -1)
        // int2 = 258 = 0x0102
        XCTAssertEqual(try Int16.decode([0x01, 0x02], oid: PostgresOID.int2, format: .binary), 258)
    }

    // MARK: Floating point

    func testDoubleBinaryRoundTrip() throws {
        var bits = UInt64(3.5.bitPattern).bigEndian
        let bytes = withUnsafeBytes(of: &bits) { Array($0) }
        XCTAssertEqual(try Double.decode(bytes, oid: PostgresOID.float8, format: .binary), 3.5)
        XCTAssertEqual(try Double.decode(Array("3.5".utf8), oid: PostgresOID.float8, format: .text), 3.5)
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

    // MARK: jsonb strips its binary version header

    func testJSONBBinaryHeader() throws {
        let json = "{\"a\":1}"
        let bytes: [UInt8] = [0x01] + Array(json.utf8)
        XCTAssertEqual(try String.decode(bytes, oid: PostgresOID.jsonb, format: .binary), json)
    }
}
