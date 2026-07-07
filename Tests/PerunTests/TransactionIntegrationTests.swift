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
