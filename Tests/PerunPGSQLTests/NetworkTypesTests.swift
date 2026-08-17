import Foundation
import XCTest
@testable import PerunPGSQL

/// `PostgresInet` (`inet`/`cidr`): IPv4 and IPv6 text parsing/formatting, binary encode and
/// decode, and a live round-trip.
final class NetworkTypesTests: XCTestCase {

    func testIPv4() throws {
        let decoded = try PostgresInet.decode(Array("192.168.1.5/24".utf8), oid: PostgresOID.inet, format: .text)
        XCTAssertEqual(decoded, inet(address: [192, 168, 1, 5], prefixLength: 24))

        XCTAssertEqual(inet(address: [192, 168, 1, 5]).postgresText, "192.168.1.5")   // /32 host omits prefix
        XCTAssertEqual(inet(address: [192, 168, 1, 0], prefixLength: 24, isCIDR: true).postgresText,
                       "192.168.1.0/24")
        // Binary: family, bits, is_cidr, length, address.
        XCTAssertEqual(inet(address: [192, 168, 1, 5]).postgresBinary(), [2, 32, 0, 4, 192, 168, 1, 5])
        XCTAssertEqual(try PostgresInet.decode([2, 32, 0, 4, 192, 168, 1, 5], oid: PostgresOID.inet, format: .binary),
                       inet(address: [192, 168, 1, 5]))
        XCTAssertEqual(inet(address: [192, 168, 1, 5]).postgresTypeOID, 869)             // inet
        XCTAssertEqual(inet(address: [10, 0, 0, 0], prefixLength: 8, isCIDR: true).postgresTypeOID, 650)   // cidr
    }

    func testIPv6ParsingAndFormatting() throws {
        // Zero-compression round-trips through the verbose form.
        let compressed = try XCTUnwrap(parseIPv6("2001:db8::1"))
        XCTAssertEqual(inet(address: compressed).postgresText, "2001:db8:0:0:0:0:0:1")
        XCTAssertEqual(parseIPv6("2001:db8:0:0:0:0:0:1"), compressed)

        XCTAssertEqual(parseIPv6("::1"), Array(repeating: 0, count: 15) + [1])                   // loopback
        XCTAssertEqual(parseIPv6("::ffff:1.2.3.4"),
                       Array(repeating: 0, count: 10) + [0xFF, 0xFF, 1, 2, 3, 4])                // embedded IPv4
        XCTAssertNil(parseIPv6("2001:db8:::1"))                                                  // triple colon
        XCTAssertNil(parseIPv4("256.1.1.1"))                                                     // octet out of range
    }

    func testRejectsMalformedText() {
        // Malformed text must throw a clean decodingFailed — never trap, and never over-accept a
        // value PostgreSQL itself rejects.
        func decode(_ text: String) throws -> PostgresInet {
            try PostgresInet.decode(Array(text.utf8), oid: PostgresOID.inet, format: .text)
        }
        XCTAssertThrowsError(try decode(""))                 // empty
        XCTAssertThrowsError(try decode("/"))                // no address
        XCTAssertThrowsError(try decode("192.168.1.1/"))     // trailing slash — a bare `/`, not a /32
        XCTAssertThrowsError(try decode("2001:db8::1/"))     // same for IPv6
    }

    func testRejectsMalformedBinary() {
        func decode(_ bytes: [UInt8]) throws -> PostgresInet {
            try PostgresInet.decode(bytes, oid: PostgresOID.inet, format: .binary)
        }
        XCTAssertThrowsError(try decode([3, 32, 0, 4, 192, 168, 1, 5]))   // family 3 (IPv6) with a 4-byte address
        XCTAssertThrowsError(try decode([2, 200, 0, 4, 1, 2, 3, 4]))      // prefix 200 wider than 32
        XCTAssertThrowsError(try decode([2, 32, 0, 4, 1, 2, 3, 4, 99]))   // a trailing byte past the address
        XCTAssertThrowsError(try decode([2, 32, 0, 4, 1, 2, 3]))          // address too short
    }

    func testInitRejectsInvalidAddressWidth() {
        // The public initializer must never trap on a stray length: a non-4/16-byte address has no
        // valid prefix or wire form, so it fails rather than crashing on `UInt8(count * 8)`.
        XCTAssertNil(PostgresInet(address: Array(repeating: 0, count: 32)))   // the finding's repro (would trap)
        XCTAssertNil(PostgresInet(address: []))
        XCTAssertNil(PostgresInet(address: [1, 2, 3]))
        XCTAssertNotNil(PostgresInet(address: [192, 168, 1, 5]))              // 4 bytes — IPv4
        XCTAssertNotNil(PostgresInet(address: Array(repeating: 0, count: 16)))// 16 bytes — IPv6

        // `address` is a public var: a value mutated to an invalid width formats to nil, not a trap.
        var mutated = inet(address: [192, 168, 1, 5])
        mutated.address = Array(repeating: 0, count: 32)
        XCTAssertNil(mutated.postgresText)
        XCTAssertNil(mutated.postgresBinary())
    }

    func testNetworkRoundTripLive() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())

        let cases: [(type: String, value: PostgresInet)] = [
            ("inet", inet(address: [192, 168, 1, 5], prefixLength: 24)),
            ("cidr", inet(address: [10, 0, 0, 0], prefixLength: 8, isCIDR: true)),
            ("inet", inet(address: try XCTUnwrap(parseIPv6("2001:db8::1")))),
            ("cidr", inet(address: try XCTUnwrap(parseIPv6("2001:db8::")), prefixLength: 32, isCIDR: true)),
        ]
        for item in cases {
            for format in [PostgresFormat.text, .binary] {
                let back: PostgresInet = try await connection.query(
                    "SELECT $1::\(item.type) AS v", [item.value], resultFormat: format).rows[0].decode("v")
                XCTAssertEqual(back, item.value, "\(item.type) round-trip (\(format))")
            }
        }

        // Decode a server-produced value and an inet[] array.
        let produced: PostgresInet = try await connection.query("SELECT inet '192.168.1.5/24' AS v").rows[0].decode("v")
        XCTAssertEqual(produced, inet(address: [192, 168, 1, 5], prefixLength: 24))
        let list: [PostgresInet] = try await connection.query("SELECT ARRAY[inet '10.0.0.1', inet '10.0.0.2'] AS v")
            .rows[0].decodeArray("v", of: PostgresInet.self)
        XCTAssertEqual(list, [inet(address: [10, 0, 0, 1]), inet(address: [10, 0, 0, 2])])

        try await connection.close()
    }

    // MARK: - Helpers

    /// Force-unwrapping constructor for the valid (4- or 16-byte) test addresses, so the failable
    /// `PostgresInet.init?` doesn't clutter every call site.
    private func inet(address: [UInt8], prefixLength: UInt8? = nil, isCIDR: Bool = false) -> PostgresInet {
        PostgresInet(address: address, prefixLength: prefixLength, isCIDR: isCIDR)!
    }
}
