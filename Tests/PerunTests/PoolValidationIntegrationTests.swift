import XCTest
@testable import PerunPGSQL

/// Live tests for `PostgresClient`'s validate-on-borrow: a healthy idle connection is
/// reused, but one the server closed while idle is detected, discarded, and replaced —
/// rather than handed to a borrower whose first query would fail.
final class PoolValidationIntegrationTests: XCTestCase {

    func testHealthyIdleConnectionIsReused() async throws {
        let pool = PostgresClient(configuration: try integrationConfiguration(), maxConnections: 1)

        let pid1 = try await pool.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)
        let pid2 = try await pool.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)
        // The liveness probe must not false-positive: the same backend is reused.
        XCTAssertEqual(pid1, pid2, "a healthy idle connection should be reused, not discarded")

        await pool.shutdown()
    }

    func testTerminatedIdleConnectionIsReplaced() async throws {
        let configuration = try integrationConfiguration()
        let pool = PostgresClient(configuration: configuration, maxConnections: 1)

        // Open the pool's one connection and note its backend, then return it to idle.
        let pid = try await pool.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)

        // Terminate that backend from a separate connection; the server sends a termination
        // error and closes the socket the pool is holding idle.
        let killer = try await PostgresConnection.connect(configuration)
        _ = try await killer.query("SELECT pg_terminate_backend(\(pid))")
        try await killer.close()

        // Give the server a moment to deliver the termination and close.
        try await Task.sleep(nanoseconds: 300_000_000)

        // The pool must validate, discard the dead connection, and open a fresh one — the
        // borrower's query succeeds on a new backend rather than failing.
        let pid2 = try await pool.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)
        XCTAssertNotEqual(pid2, pid, "the terminated connection should have been replaced")

        await pool.shutdown()
    }

    // MARK: - Helpers

}
