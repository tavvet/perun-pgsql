import Foundation
import XCTest
@testable import PerunPGSQL

/// Live round-trip of binary parameters: encode → server → decode, proving the
/// server accepts our binary wire form. Skipped unless PERUN_PGSQL_INTEGRATION=1.
final class BinaryParameterIntegrationTests: XCTestCase {

    func testBinaryParametersRoundTrip() async throws {
        let configuration = try integrationConfiguration()
        let pool = PostgresClient(configuration: configuration, maxConnections: 1)

        let row = try await pool.query(
            """
            SELECT $1::int8 AS i, $2::int4 AS j, $3::int2 AS k, $4::float8 AS d,
                   $5::float4 AS f, $6::bool AS b, $7::text AS t
            """,
            [Int(9_000_000_000), Int32(-42), Int16(7),
             3.5 as Double, 0.5 as Float, true, "héllo"],
            parameterFormat: .binary).rows[0]

        XCTAssertEqual(try row.decode("i", as: Int64.self), 9_000_000_000)
        XCTAssertEqual(try row.decode("j", as: Int32.self), -42)
        XCTAssertEqual(try row.decode("k", as: Int16.self), 7)
        XCTAssertEqual(try row.decode("d", as: Double.self), 3.5)
        XCTAssertEqual(try row.decode("f", as: Float.self), 0.5)
        XCTAssertEqual(try row.decode("b", as: Bool.self), true)
        XCTAssertEqual(try row.decode("t", as: String.self), "héllo")

        await pool.shutdown()
    }

    func testBinaryParametersWithNullAndBinaryResults() async throws {
        let configuration = try integrationConfiguration()
        let pool = PostgresClient(configuration: configuration, maxConnections: 1)

        // NULL parameter in binary mode, and binary result columns.
        let row = try await pool.query("SELECT $1::int8 AS a, $2::text AS b",
                                       [Int(1), nil],
                                       parameterFormat: .binary,
                                       resultFormat: .binary).rows[0]

        XCTAssertEqual(try row.decode("a", as: Int.self), 1)
        XCTAssertTrue(try row.cell("b").isNull)

        await pool.shutdown()
    }

    func testUUIDAndDateParametersRoundTrip() async throws {
        let configuration = try integrationConfiguration()
        let pool = PostgresClient(configuration: configuration, maxConnections: 1)

        let uuid = UUID()
        let date = Date(timeIntervalSince1970: 1_783_457_424.5)

        for format in [PostgresFormat.text, .binary] {
            let row = try await pool.query("SELECT $1::uuid AS u, $2::timestamptz AS t",
                                           [uuid, date],
                                           parameterFormat: format).rows[0]
            XCTAssertEqual(try row.decode("u", as: UUID.self), uuid, "uuid via \(format)")
            XCTAssertEqual(try row.decode("t", as: Date.self).timeIntervalSince1970,
                           date.timeIntervalSince1970, accuracy: 0.000_001, "date via \(format)")
        }

        await pool.shutdown()
    }

    private func integrationConfiguration() throws -> ConnectionConfiguration {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PERUN_PGSQL_INTEGRATION"] == "1" else {
            throw XCTSkip("set PERUN_PGSQL_INTEGRATION=1 to run live PostgreSQL integration tests")
        }

        let tlsMode: TLSMode
        switch environment["PGSSLMODE"] {
        case "disable": tlsMode = .disable
        case "prefer", "allow-plaintext-fallback": tlsMode = .allowPlaintextFallback
        case "require", "encrypt-without-verification": tlsMode = .encryptWithoutVerification
        case "verify-full": tlsMode = .verifyFull
        default: tlsMode = .verifyFull
        }

        return ConnectionConfiguration(
            host: environment["PGHOST"] ?? "localhost",
            port: UInt16(environment["PGPORT"] ?? "") ?? 5432,
            user: environment["PGUSER"] ?? "perun",
            database: environment["PGDATABASE"] ?? "perun",
            password: environment["PGPASSWORD"],
            tlsMode: tlsMode
        )
    }
}
