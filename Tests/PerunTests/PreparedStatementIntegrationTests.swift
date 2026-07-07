import Foundation
import XCTest
@testable import PerunPGSQL

/// Live PostgreSQL checks for prepared-statement handle ownership. Skipped by
/// default; run with PERUN_PGSQL_INTEGRATION=1 and PG* environment variables.
final class PreparedStatementIntegrationTests: XCTestCase {

    func testPreparedStatementCannotBeUsedOnDifferentConnection() async throws {
        let configuration = try integrationConfiguration()
        let first = try await PostgresConnection.connect(configuration)
        let second = try await PostgresConnection.connect(configuration)

        do {
            let statement = try await first.prepare("SELECT 42::int AS answer")
            let result = try await first.execute(statement)
            XCTAssertEqual(result.rows[0]["answer"]?.int(), 42)

            do {
                _ = try await second.execute(statement)
                XCTFail("expected foreign prepared-statement execution to throw")
            } catch PerunError.preparedStatementConnectionMismatch {
                // Expected: prepared statements are scoped to their creating connection.
            }

            do {
                try await second.closePrepared(statement)
                XCTFail("expected foreign prepared-statement close to throw")
            } catch PerunError.preparedStatementConnectionMismatch {
                // Expected.
            }

            try await first.closePrepared(statement)
        } catch {
            _ = try? await first.close()
            _ = try? await second.close()
            throw error
        }

        _ = try? await first.close()
        _ = try? await second.close()
    }

    private func integrationConfiguration() throws -> ConnectionConfiguration {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PERUN_PGSQL_INTEGRATION"] == "1" else {
            throw XCTSkip("set PERUN_PGSQL_INTEGRATION=1 to run live PostgreSQL integration tests")
        }

        let tlsMode: TLSMode
        switch environment["PGSSLMODE"] {
        case "disable": tlsMode = .disable
        case "require": tlsMode = .require
        case "verify-full": tlsMode = .verifyFull
        default: tlsMode = .prefer
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
