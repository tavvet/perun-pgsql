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

    func testLifetimeRecycledOnWaiterHandoff() async throws {
        // maxConnections 1: one task holds the only connection until it is past its lifetime,
        // while a second task waits for it. On release the expired connection must be recycled
        // for the waiter (a fresh backend), not handed over directly.
        let pool = PostgresClient(configuration: try integrationConfiguration(),
                                  maxConnections: 1, maxConnectionLifetime: .seconds(1))

        async let held: Int = pool.withConnection { connection in
            let pid = try await connection.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)
            try await Task.sleep(for: .seconds(1.5))          // age past the lifetime while holding it
            return pid
        }
        try await Task.sleep(for: .milliseconds(200))         // let the holder check the connection out first

        let waiterPID = try await pool.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)
        let heldPID = try await held
        XCTAssertNotEqual(waiterPID, heldPID,
                          "an over-lifetime connection must be recycled even on a direct waiter handoff")

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

}
