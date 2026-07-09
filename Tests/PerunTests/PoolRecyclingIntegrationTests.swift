import XCTest
@testable import PerunPGSQL

/// Live tests for age-based pool recycling: idle connections are reaped, connections past
/// their lifetime are replaced, and with no limits set nothing changes (opt-in).
final class PoolRecyclingIntegrationTests: XCTestCase {

    func testIdleConnectionsAreReaped() async throws {
        let pool = PostgresClient(configuration: try integrationConfiguration(),
                                  maxConnections: 2, maxIdleTime: .seconds(1))

        _ = try await pool.query("SELECT 1")           // opens a connection, returns it to idle
        let afterQuery = await pool.connectionCount
        XCTAssertEqual(afterQuery, 1)

        try await Task.sleep(for: .seconds(2))          // past maxIdleTime + a reaper scan
        let afterIdle = await pool.connectionCount
        XCTAssertEqual(afterIdle, 0, "an idle connection past maxIdleTime should be reaped")

        // The pool still works — it reopens on demand.
        let answer = try await pool.query("SELECT 42 AS a").rows[0].decode("a", as: Int.self)
        XCTAssertEqual(answer, 42)
        await pool.shutdown()
    }

    func testConnectionsAreRecycledByLifetime() async throws {
        let pool = PostgresClient(configuration: try integrationConfiguration(),
                                  maxConnections: 1, maxConnectionLifetime: .seconds(1))

        let pid1 = try await pool.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)
        try await Task.sleep(for: .seconds(1.5))            // past maxConnectionLifetime
        let pid2 = try await pool.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)
        XCTAssertNotEqual(pid2, pid1, "a connection past its lifetime should be recycled")

        await pool.shutdown()
    }

    func testNoRecyclingWithoutLimits() async throws {
        let pool = PostgresClient(configuration: try integrationConfiguration(), maxConnections: 1)

        let pid1 = try await pool.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)
        try await Task.sleep(for: .seconds(1))
        let pid2 = try await pool.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)
        XCTAssertEqual(pid1, pid2, "with no limits, an idle connection is reused indefinitely")

        await pool.shutdown()
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
