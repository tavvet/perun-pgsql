import Foundation
import XCTest
@testable import PerunPGSQL

/// Live PostgreSQL checks for transaction/pool behavior. Skipped by default;
/// run with PERUN_PGSQL_INTEGRATION=1 and PG* environment variables.
final class TransactionIntegrationTests: XCTestCase {

    func testTransactionsCommitRollbackAndDiscardOpenPoolTransactions() async throws {
        let configuration = try integrationConfiguration()
        let pool = PostgresClient(configuration: configuration, maxConnections: 1)
        let table = "perun_tx_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_").lowercased())"

        do {
            try await pool.query("CREATE TABLE \(table) (id int primary key, note text)")

            _ = try await pool.withTransaction { tx in
                try await tx.query("INSERT INTO \(table) (id, note) VALUES ($1, $2)", [1, "committed"])
            }
            var count = try await pool.query("SELECT count(*)::int FROM \(table)")
            XCTAssertEqual(count.rows[0][0].int(), 1)

            do {
                try await pool.withTransaction { tx in
                    try await tx.query("INSERT INTO \(table) (id, note) VALUES ($1, $2)", [2, "rolled back"])
                    try await tx.query("SELECT * FROM perun_missing_table_for_rollback")
                }
                XCTFail("expected transaction body to throw")
            } catch PerunError.server {
                // Expected: the missing table aborts the transaction and withTransaction rolls back.
            }

            count = try await pool.query("SELECT count(*)::int FROM \(table)")
            XCTAssertEqual(count.rows[0][0].int(), 1)

            // Misusing pool.query("BEGIN") should not poison the pool; release
            // observes ReadyForQuery(T), discards that connection, and the next
            // query opens a clean one.
            try await pool.query("BEGIN")
            count = try await pool.query("SELECT count(*)::int FROM \(table)")
            XCTAssertEqual(count.rows[0][0].int(), 1)
        } catch {
            _ = try? await pool.query("DROP TABLE IF EXISTS \(table)")
            await pool.shutdown()
            throw error
        }

        _ = try? await pool.query("DROP TABLE IF EXISTS \(table)")
        await pool.shutdown()
    }

    /// Releasing a connection concurrently with shutdown() must not leave it in
    /// the idle list (which shutdown has already drained), leaking it. Stress the
    /// window; with the fix `connectionCount` is always 0 once everything settles.
    func testShutdownDoesNotLeakConcurrentlyReleasedConnections() async throws {
        let configuration = try integrationConfiguration()
        for _ in 0 ..< 100 {
            let pool = PostgresClient(configuration: configuration, maxConnections: 4)
            _ = try await pool.query("SELECT 1")                 // warm one idle connection
            let racer = Task { _ = try? await pool.query("SELECT 1") }   // release races shutdown
            await pool.shutdown()
            _ = await racer.value
            let remaining = await pool.connectionCount
            XCTAssertEqual(remaining, 0, "shutdown leaked a connection back into the pool")
        }
    }

    /// A non-server error (one thrown by the caller's closure, or a decode error)
    /// leaves the wire synchronized, so the pooled connection must be reused, not
    /// dropped. With maxConnections 1, reuse keeps `connectionCount` at 1.
    func testHealthyConnectionReusedAfterLocalError() async throws {
        struct BodyError: Error {}
        let configuration = try integrationConfiguration()
        let pool = PostgresClient(configuration: configuration, maxConnections: 1)

        _ = try await pool.query("SELECT 1")
        let afterWarmup = await pool.connectionCount
        XCTAssertEqual(afterWarmup, 1)

        // Error thrown by the closure after a completed query.
        do {
            try await pool.withConnection { connection -> Void in
                _ = try await connection.query("SELECT 1")
                throw BodyError()
            }
            XCTFail("expected BodyError")
        } catch is BodyError {}
        let afterClosureError = await pool.connectionCount
        XCTAssertEqual(afterClosureError, 1, "healthy connection was dropped on a closure error")

        // A decode error is likewise non-desyncing.
        do {
            _ = try await pool.withConnection { connection in
                let result = try await connection.query("SELECT 'x'::text AS t")
                return try result.rows[0].decode("t", as: Int.self)
            }
            XCTFail("expected a decoding error")
        } catch let error as PerunError {
            guard case .decodingFailed = error else { throw error }
        }
        let afterDecodeError = await pool.connectionCount
        XCTAssertEqual(afterDecodeError, 1, "healthy connection was dropped on a decode error")

        await pool.shutdown()
    }

}
