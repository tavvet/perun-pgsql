import Foundation
import XCTest
@testable import PerunPGSQL

/// Cancelling a task parked for a pooled connection, or for the per-connection wire
/// lock, must fail that task with `CancellationError` and leave the pool / connection
/// usable — never orphan the waiter in its queue. Skipped unless
/// PERUN_PGSQL_INTEGRATION=1.
final class CancellationIntegrationTests: XCTestCase {

    func testPoolWaiterCancellationFailsAndKeepsPoolUsable() async throws {
        let pool = PostgresClient(configuration: try integrationConfiguration(), maxConnections: 1)

        // Occupy the single connection for a while.
        let holder = Task {
            try await pool.withConnection { connection in
                _ = try await connection.query("SELECT pg_sleep(0.5)")
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)   // let the holder check it out

        // This one has to park — the only connection is busy.
        let waiter = Task { try await pool.query("SELECT 1") }
        try await Task.sleep(nanoseconds: 60_000_000)    // let it park in the queue
        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("a cancelled pool waiter should throw")
        } catch is CancellationError {
            // expected: it left the queue instead of being handed a connection later
        }

        try await holder.value                           // holder finishes normally
        // The cancelled waiter left the queue clean, so the pool still hands out work.
        let n = try await pool.query("SELECT 1 AS n").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(n, 1)
        await pool.shutdown()
    }

    func testWireLockWaiterCancellationFailsAndKeepsConnectionUsable() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())

        // Hold the wire lock with a slow query.
        let holder = Task { _ = try await connection.query("SELECT pg_sleep(0.5)") }
        try await Task.sleep(nanoseconds: 100_000_000)

        // A second query on the same connection has to park on the wire lock.
        let waiter = Task { try await connection.query("SELECT 1") }
        try await Task.sleep(nanoseconds: 60_000_000)
        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("a cancelled wire-lock waiter should throw")
        } catch is CancellationError {
            // expected
        }

        try await holder.value
        // The lock queue is clean and the connection is still usable.
        let n = try await connection.query("SELECT 1 AS n").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(n, 1)
        try await connection.close()
    }

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
