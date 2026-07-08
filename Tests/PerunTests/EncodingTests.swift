import XCTest
import Foundation
@testable import PerunPGSQL

/// Binary parameter encoding: the byte-exact wire form for each encodable type,
/// plus the `Bind` message layout when binary parameters are requested.
final class EncodingTests: XCTestCase {

    func testIntegerBinaryEncoding() {
        XCTAssertEqual(Int16(258).postgresBinary(), [0x01, 0x02])                 // int2
        XCTAssertEqual(Int16(-2).postgresBinary(), [0xFF, 0xFE])
        XCTAssertEqual(Int32(0x0102_0304).postgresBinary(), [0x01, 0x02, 0x03, 0x04])  // int4
        XCTAssertEqual(Int64(1).postgresBinary(), [0, 0, 0, 0, 0, 0, 0, 1])       // int8
        XCTAssertEqual(Int(-1).postgresBinary(), [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    func testFloatingPointBinaryEncoding() {
        XCTAssertEqual((3.5 as Double).postgresBinary(), [0x40, 0x0C, 0, 0, 0, 0, 0, 0])  // float8
        XCTAssertEqual((3.5 as Float).postgresBinary(), [0x40, 0x60, 0, 0])               // float4
    }

    func testBoolAndTextBinaryEncoding() {
        XCTAssertEqual(true.postgresBinary(), [1])
        XCTAssertEqual(false.postgresBinary(), [0])
        XCTAssertEqual("hi".postgresBinary(), [0x68, 0x69])   // text binary == UTF-8
    }

    func testTypeOIDs() {
        XCTAssertEqual(Int(0).postgresTypeOID, 20)     // int8
        XCTAssertEqual(Int16(0).postgresTypeOID, 21)   // int2
        XCTAssertEqual(Int32(0).postgresTypeOID, 23)   // int4
        XCTAssertEqual((0.0 as Double).postgresTypeOID, 701)
        XCTAssertEqual((0.0 as Float).postgresTypeOID, 700)
        XCTAssertEqual(true.postgresTypeOID, 16)
        XCTAssertEqual("x".postgresTypeOID, 25)
    }

    func testBindBinaryParameterLayout() throws {
        let message = try FrontendMessage.bind(portal: "", statement: "",
                                               parameters: [Int(42)], parameterFormat: .binary)
        // Tail after portal(1) + statement(1): per-parameter format codes, then values.
        let expectedTail: [UInt8] = [
            0x00, 0x01,                              // 1 parameter format code
            0x00, 0x01,                              // code = 1 (binary)
            0x00, 0x01,                              // 1 parameter value
            0x00, 0x00, 0x00, 0x08,                  // value length 8
            0, 0, 0, 0, 0, 0, 0, 42,                 // int8(42), big-endian
            0x00, 0x00,                              // 0 result format codes (text)
        ]
        XCTAssertEqual(Array(message.suffix(expectedTail.count)), expectedTail)
    }

    func testBindBinaryFallsBackToTextForNull() throws {
        // A NULL element carries no bytes; its format code is written as text (0).
        let message = try FrontendMessage.bind(portal: "", statement: "",
                                               parameters: [nil], parameterFormat: .binary)
        let expectedTail: [UInt8] = [
            0x00, 0x01,                              // 1 format code
            0x00, 0x00,                              // code = 0 (text) for the NULL
            0x00, 0x01,                              // 1 value
            0xFF, 0xFF, 0xFF, 0xFF,                  // length -1 = SQL NULL
            0x00, 0x00,                              // 0 result format codes
        ]
        XCTAssertEqual(Array(message.suffix(expectedTail.count)), expectedTail)
    }

    func testUUIDEncoding() {
        let uuid = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
        XCTAssertEqual(uuid.postgresBinary(),
                       [0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
                        0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00])
        XCTAssertEqual(uuid.postgresTypeOID, 2950)
        XCTAssertEqual(uuid.postgresText?.lowercased(), "550e8400-e29b-41d4-a716-446655440000")
    }

    func testDateEncoding() throws {
        // PostgreSQL's epoch (2000-01-01 00:00:00 UTC) → 0 microseconds.
        let epoch = Date(timeIntervalSince1970: 946_684_800)
        XCTAssertEqual(epoch.postgresBinary(), [0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(epoch.postgresTypeOID, 1184)
        XCTAssertEqual(epoch.postgresText, "2000-01-01 00:00:00.000000+00")

        // Encode → decode round-trips to the same instant in both formats.
        let instant = Date(timeIntervalSince1970: 1_783_457_424.5)   // exact half-second
        let viaBinary = try Date.decode(instant.postgresBinary()!, oid: PostgresOID.timestamptz, format: .binary)
        XCTAssertEqual(viaBinary.timeIntervalSince1970, instant.timeIntervalSince1970, accuracy: 0.000_001)
        let viaText = try Date.decode(Array(instant.postgresText!.utf8), oid: PostgresOID.timestamptz, format: .text)
        XCTAssertEqual(viaText.timeIntervalSince1970, instant.timeIntervalSince1970, accuracy: 0.000_001)
    }
}
