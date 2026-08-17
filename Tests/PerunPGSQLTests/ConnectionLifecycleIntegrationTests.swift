import XCTest
@testable import PerunPGSQL

/// A connection (and a pool) dropped without an explicit `close()` / `shutdown()` must still
/// deallocate, so its socket fd, reader task and buffers are released rather than leaked. The
/// background reader must not pin the actor alive after the wire goes idle.
final class ConnectionLifecycleIntegrationTests: XCTestCase {

    func testDroppedConnectionDeallocatesWithoutExplicitClose() async throws {
        weak var weakConnection: PostgresConnection?
        do {
            let connection = try await PostgresConnection.connect(integrationConfiguration())
            _ = try await connection.query("SELECT 1")
            weakConnection = connection
            // `connection` goes out of scope here with no close() call.
        }
        // The reader exits once the queue drains, releasing its hold on the actor; give the
        // task a moment to finish so ARC can reclaim it.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(weakConnection,
                     "a dropped connection must deallocate — a parked reader pinning it would leak the fd")
    }

    func testDroppedPoolDeallocatesItsConnectionsWithoutShutdown() async throws {
        weak var weakConnection: PostgresConnection?
        do {
            let pool = PostgresClient(configuration: try integrationConfiguration(), maxConnections: 2)
            weakConnection = try await pool.withConnection { connection in
                _ = try await connection.query("SELECT 1")
                return connection            // observe the pooled connection weakly
            }
            // `pool` goes out of scope here with no shutdown() call.
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(weakConnection,
                     "dropping a pool without shutdown() must still let its idle connections deallocate")
    }

    // MARK: - Helpers

}
