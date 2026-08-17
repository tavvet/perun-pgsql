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

}
