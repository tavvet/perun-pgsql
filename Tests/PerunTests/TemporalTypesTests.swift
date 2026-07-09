import XCTest
@testable import PerunPGSQL

/// `PostgresInterval` and `PostgresTime`: text/binary encode and decode, plus a live
/// round-trip that also decodes values PostgreSQL produces.
final class TemporalTypesTests: XCTestCase {

    // MARK: - Interval (no server)

    func testIntervalBinaryEncoding() {
        // Binary layout: int64 microseconds, int32 days, int32 months.
        XCTAssertEqual(PostgresInterval(months: 1, days: 2, microseconds: 3).postgresBinary(),
                       [0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 2, 0, 0, 0, 1])
        XCTAssertEqual(PostgresInterval(months: 1, days: 2, microseconds: 3).postgresTypeOID, 1186)
    }

    func testIntervalTextEncoding() {
        XCTAssertEqual(PostgresInterval(months: 3, days: 2, microseconds: 5_500_000).postgresText,
                       "3 mons 2 days 5.500000 secs")
        // A sub-second negative keeps its sign.
        XCTAssertEqual(PostgresInterval(microseconds: -500_000).postgresText,
                       "0 mons 0 days -0.500000 secs")
    }

    func testIntervalBinaryDecoding() throws {
        let interval = try PostgresInterval.decode(
            [0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 2, 0, 0, 0, 1], oid: 1186, format: .binary)
        XCTAssertEqual(interval, PostgresInterval(months: 1, days: 2, microseconds: 3))
    }

    func testIntervalTextDecoding() throws {
        func decode(_ text: String) throws -> PostgresInterval {
            try PostgresInterval.decode(Array(text.utf8), oid: 1186, format: .text)
        }
        XCTAssertEqual(try decode("1 year 2 mons 3 days 04:05:06"),
                       PostgresInterval(months: 14, days: 3, microseconds: 14_706_000_000))
        XCTAssertEqual(try decode("-1 days +02:03:04"),
                       PostgresInterval(months: 0, days: -1, microseconds: 7_384_000_000))
        XCTAssertEqual(try decode("00:00:00.5"), PostgresInterval(microseconds: 500_000))
        XCTAssertEqual(try decode("2 mons"), PostgresInterval(months: 2))
    }

    // MARK: - Time (no server)

    func testTimeEncoding() {
        XCTAssertEqual(PostgresTime(microseconds: 1).postgresBinary(), [0, 0, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(PostgresTime(hour: 4, minute: 5, second: 6, microsecond: 789).postgresText,
                       "04:05:06.000789")
        XCTAssertEqual(PostgresTime(hour: 4, minute: 5, second: 6, microsecond: 789).postgresTypeOID, 1083)
    }

    func testTimeDecoding() throws {
        let binary = try PostgresTime.decode([0, 0, 0, 0, 0, 0, 0, 1], oid: 1083, format: .binary)
        XCTAssertEqual(binary, PostgresTime(microseconds: 1))
        let text = try PostgresTime.decode(Array("04:05:06.000789".utf8), oid: 1083, format: .text)
        XCTAssertEqual(text, PostgresTime(hour: 4, minute: 5, second: 6, microsecond: 789))
    }

    func testTimeTzEncoding() {
        let value = PostgresTimeTz(time: PostgresTime(hour: 12, minute: 34, second: 56), zoneOffsetSeconds: 18000)
        XCTAssertEqual(value.postgresText, "12:34:56.000000+05:00")
        XCTAssertEqual(value.postgresTypeOID, 1266)
        // Binary: int64 microseconds, int32 zone (seconds *west* = negated offset).
        XCTAssertEqual(PostgresTimeTz(time: PostgresTime(microseconds: 1), zoneOffsetSeconds: 18000).postgresBinary(),
                       [0, 0, 0, 0, 0, 0, 0, 1, 0xFF, 0xFF, 0xB9, 0xB0])   // -18000 = 0xFFFFB9B0
    }

    func testTimeTzDecoding() throws {
        let text = try PostgresTimeTz.decode(Array("12:34:56.789+05:30".utf8), oid: 1266, format: .text)
        XCTAssertEqual(text, PostgresTimeTz(time: PostgresTime(hour: 12, minute: 34, second: 56, microsecond: 789_000),
                                            zoneOffsetSeconds: 19800))
        let binary = try PostgresTimeTz.decode(
            [0, 0, 0, 0, 0, 0, 0, 1, 0xFF, 0xFF, 0xB9, 0xB0], oid: 1266, format: .binary)
        XCTAssertEqual(binary, PostgresTimeTz(time: PostgresTime(microseconds: 1), zoneOffsetSeconds: 18000))
    }

    func testTimeTzRejectsMalformedOffset() {
        func decode(_ text: String) throws -> PostgresTimeTz {
            try PostgresTimeTz.decode(Array(text.utf8), oid: 1266, format: .text)
        }
        XCTAssertThrowsError(try decode("12:34:56+05:xx"))        // non-numeric minutes (not silently zeroed)
        XCTAssertThrowsError(try decode("12:34:56+05:99"))        // minutes out of range
        XCTAssertThrowsError(try decode("12:34:56+05:30:99"))     // seconds out of range
        XCTAssertThrowsError(try decode("12:34:56+05:30:45:00"))  // too many offset parts
        XCTAssertThrowsError(try decode("12:34:56+2147483647:00")) // offset hours overflow → error, not a trap
        XCTAssertThrowsError(try decode("12:34:56+24:00"))         // offset hours out of range
    }

    func testClockRejectsOverflowAndOutOfRange() throws {
        func time(_ text: String) throws -> PostgresTime {
            try PostgresTime.decode(Array(text.utf8), oid: 1083, format: .text)
        }
        XCTAssertThrowsError(try time("99999999999999:00:00"))   // hours overflow → error, not a trap
        XCTAssertThrowsError(try time("00:99:00"))               // minutes out of range
        XCTAssertThrowsError(try time("00:00:99"))               // seconds out of range
        // The same guard protects interval's time part.
        XCTAssertThrowsError(try PostgresInterval.decode(
            Array("99999999999999:00:00".utf8), oid: 1186, format: .text))
    }

    // MARK: - Live round-trip

    func testTemporalRoundTripLive() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())

        let interval = PostgresInterval(months: 14, days: 3, microseconds: 14_706_789_000)
        for format in [PostgresFormat.text, .binary] {
            let back: PostgresInterval = try await connection.query(
                "SELECT $1::interval AS v", [interval], resultFormat: format).rows[0].decode("v")
            XCTAssertEqual(back, interval, "interval round-trip (\(format))")
        }

        let time = PostgresTime(hour: 13, minute: 14, second: 15, microsecond: 678_900)
        for format in [PostgresFormat.text, .binary] {
            let back: PostgresTime = try await connection.query(
                "SELECT $1::time AS v", [time], resultFormat: format).rows[0].decode("v")
            XCTAssertEqual(back, time, "time round-trip (\(format))")
        }

        let timetz = PostgresTimeTz(time: PostgresTime(hour: 13, minute: 14, second: 15, microsecond: 678_900),
                                    zoneOffsetSeconds: 19800)   // +05:30
        for format in [PostgresFormat.text, .binary] {
            let back: PostgresTimeTz = try await connection.query(
                "SELECT $1::timetz AS v", [timetz], resultFormat: format).rows[0].decode("v")
            XCTAssertEqual(back, timetz, "timetz round-trip (\(format))")
        }

        // Decode values PostgreSQL renders itself.
        let produced: PostgresInterval = try await connection.query("SELECT interval '1 mon 5 days 06:00:00' AS v")
            .rows[0].decode("v")
        XCTAssertEqual(produced, PostgresInterval(months: 1, days: 5, microseconds: 21_600_000_000))

        // Arrays of temporal types decode too.
        let days: [PostgresInterval] = try await connection.query(
            "SELECT ARRAY[interval '1 day', interval '2 days'] AS v").rows[0].decodeArray("v", of: PostgresInterval.self)
        XCTAssertEqual(days, [PostgresInterval(days: 1), PostgresInterval(days: 2)])

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
