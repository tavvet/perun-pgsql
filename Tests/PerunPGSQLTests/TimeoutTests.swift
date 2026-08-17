import XCTest
@testable import PerunPGSQL

/// `withTimeout`: the wrapper itself (no server), and — live — that a timed-out query is
/// cancelled server-side promptly and leaves the connection reusable.
final class TimeoutTests: XCTestCase {

    // MARK: - The wrapper (no server)

    func testTimeoutFiresOnSlowOperation() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await withTimeout(.milliseconds(200)) {
                try await Task.sleep(for: .seconds(10))
            }
            XCTFail("expected a timeout")
        } catch let error as PerunError {
            guard case .timedOut = error else { return XCTFail("expected .timedOut, got \(error)") }
        }
        XCTAssertLessThan(clock.now - start, .seconds(2), "the timeout should fire promptly")
    }

    func testResultReturnedWhenUnderTimeout() async throws {
        // Returns immediately with the value — it must not wait out the (long) deadline.
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await withTimeout(.seconds(30)) { 42 }
        XCTAssertEqual(value, 42)
        XCTAssertLessThan(clock.now - start, .seconds(2), "a fast operation must not wait for the deadline")
    }

    // MARK: - Live: query timeout

    func testQueryTimeoutCancelsAndLeavesConnectionUsable() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await withTimeout(.milliseconds(300)) {
                try await connection.query("SELECT pg_sleep(5)")
            }
            XCTFail("expected the slow query to time out")
        } catch let error as PerunError {
            guard case .timedOut = error else { return XCTFail("expected .timedOut, got \(error)") }
        }
        // The CancelRequest aborts pg_sleep, so this returns well under its 5s.
        XCTAssertLessThan(clock.now - start, .seconds(3), "the timeout must not wait for pg_sleep")

        // The query was cancelled and drained, so the connection is back in sync.
        let answer = try await connection.query("SELECT 42 AS a").rows[0].decode("a", as: Int.self)
        XCTAssertEqual(answer, 42)
    }

    func testFastQueryUnderTimeoutSucceeds() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        let result = try await withTimeout(.seconds(5)) {
            try await connection.query("SELECT 7 AS a")
        }
        XCTAssertEqual(try result.rows[0].decode("a", as: Int.self), 7)
    }

    func testPoolQueryTimeoutKeepsConnectionInSync() async throws {
        let pool = PostgresClient(configuration: try integrationConfiguration(), maxConnections: 1)

        do {
            _ = try await withTimeout(.milliseconds(300)) {
                try await pool.query("SELECT pg_sleep(5)")
            }
            XCTFail("expected the pooled query to time out")
        } catch let error as PerunError {
            guard case .timedOut = error else { return XCTFail("expected .timedOut, got \(error)") }
        }
        // The cancelled query drained to ReadyForQuery, so the pool kept the connection.
        let answer = try await pool.query("SELECT 9 AS a").rows[0].decode("a", as: Int.self)
        XCTAssertEqual(answer, 9)

        await pool.shutdown()
    }

    func testTransactionTimeoutRollsBackAndConnectionUsable() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }
        _ = try await connection.query("CREATE TEMP TABLE timeout_txn (id int)")

        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await withTimeout(.milliseconds(300)) {
                try await connection.withTransaction { txn in
                    try await txn.query("INSERT INTO timeout_txn VALUES (1)")
                    try await txn.query("SELECT pg_sleep(5)")     // slow — should be cancelled
                }
            }
            XCTFail("expected the transaction to time out")
        } catch let error as PerunError {
            guard case .timedOut = error else { return XCTFail("expected .timedOut, got \(error)") }
        }
        XCTAssertLessThan(clock.now - start, .seconds(3), "the transaction timeout must not wait for pg_sleep")

        // The transaction must have rolled back (the INSERT did not persist)…
        let count = try await connection.query("SELECT count(*)::int AS c FROM timeout_txn")
            .rows[0].decode("c", as: Int.self)
        XCTAssertEqual(count, 0, "a timed-out transaction must roll back")
        // …and the connection is reusable.
        let answer = try await connection.query("SELECT 42 AS a").rows[0].decode("a", as: Int.self)
        XCTAssertEqual(answer, 42)
    }

    // MARK: - Helpers

}
