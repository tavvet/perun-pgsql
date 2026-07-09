import Foundation
import XCTest
@testable import PerunPGSQL

/// `PostgresInet` (`inet`/`cidr`): IPv4 and IPv6 text parsing/formatting, binary encode and
/// decode, and a live round-trip.
final class NetworkTypesTests: XCTestCase {

    func testIPv4() throws {
        let decoded = try PostgresInet.decode(Array("192.168.1.5/24".utf8), oid: PostgresOID.inet, format: .text)
        XCTAssertEqual(decoded, PostgresInet(address: [192, 168, 1, 5], prefixLength: 24))

        XCTAssertEqual(PostgresInet(address: [192, 168, 1, 5]).postgresText, "192.168.1.5")   // /32 host omits prefix
        XCTAssertEqual(PostgresInet(address: [192, 168, 1, 0], prefixLength: 24, isCIDR: true).postgresText,
                       "192.168.1.0/24")
        // Binary: family, bits, is_cidr, length, address.
        XCTAssertEqual(PostgresInet(address: [192, 168, 1, 5]).postgresBinary(), [2, 32, 0, 4, 192, 168, 1, 5])
        XCTAssertEqual(try PostgresInet.decode([2, 32, 0, 4, 192, 168, 1, 5], oid: PostgresOID.inet, format: .binary),
                       PostgresInet(address: [192, 168, 1, 5]))
        XCTAssertEqual(PostgresInet(address: [192, 168, 1, 5]).postgresTypeOID, 869)             // inet
        XCTAssertEqual(PostgresInet(address: [10, 0, 0, 0], prefixLength: 8, isCIDR: true).postgresTypeOID, 650)   // cidr
    }

    func testIPv6ParsingAndFormatting() throws {
        // Zero-compression round-trips through the verbose form.
        let compressed = try XCTUnwrap(parseIPv6("2001:db8::1"))
        XCTAssertEqual(PostgresInet(address: compressed).postgresText, "2001:db8:0:0:0:0:0:1")
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

    func testNetworkRoundTripLive() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())

        let cases: [(type: String, value: PostgresInet)] = [
            ("inet", PostgresInet(address: [192, 168, 1, 5], prefixLength: 24)),
            ("cidr", PostgresInet(address: [10, 0, 0, 0], prefixLength: 8, isCIDR: true)),
            ("inet", PostgresInet(address: try XCTUnwrap(parseIPv6("2001:db8::1")))),
            ("cidr", PostgresInet(address: try XCTUnwrap(parseIPv6("2001:db8::")), prefixLength: 32, isCIDR: true)),
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
        XCTAssertEqual(produced, PostgresInet(address: [192, 168, 1, 5], prefixLength: 24))
        let list: [PostgresInet] = try await connection.query("SELECT ARRAY[inet '10.0.0.1', inet '10.0.0.2'] AS v")
            .rows[0].decodeArray("v", of: PostgresInet.self)
        XCTAssertEqual(list, [PostgresInet(address: [10, 0, 0, 1]), PostgresInet(address: [10, 0, 0, 2])])

        try await connection.close()
    }

    // MARK: - Helpers

    private func integrationConfiguration() throws -> ConnectionConfiguration {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PERUN_PGSQL_INTEGRATION"] == "1" else {
            throw XCTSkip("set PERUN_PGSQL_INTEGRATION=1 to run live PostgreSQL integration tests")
        }
        let tlsMode: TLSMode
        switch environment["PGSSLMODE"] {
        case "disable": tlsMode = .disable
        case "require", "encrypt-without-verification": tlsMode = .encryptWithoutVerification
        default: tlsMode = .verifyFull
        }
        return ConnectionConfiguration(
            host: environment["PGHOST"] ?? "localhost",
            port: UInt16(environment["PGPORT"] ?? "") ?? 5432,
            user: environment["PGUSER"] ?? "perun",
            database: environment["PGDATABASE"] ?? "perun",
            password: environment["PGPASSWORD"],
            tlsMode: tlsMode)
    }
}
