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

    func testLivenessCheckSeesDriverBufferedBytes() async throws {
        // readSlice reads ahead, so a read can leave a trailing message in the driver's own readBuffer
        // that the socket and OpenSSL peeks can't see. A pooled connection carrying a buffered
        // termination/error must be judged dead — otherwise the next borrower gets a stale wire.
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }
        _ = try await connection.query("SELECT 1").rows          // steady state, drained to RFQ

        let aliveWhenDrained = await connection.isProbablyAlive()
        XCTAssertTrue(aliveWhenDrained, "a freshly drained connection must look alive")

        await connection.primeReadBufferForTest(UInt8(ascii: "E"))   // a buffered ErrorResponse (termination)
        let aliveWithBuffered = await connection.isProbablyAlive()
        XCTAssertFalse(aliveWithBuffered,
                       "a buffered non-async message must make the connection look dead")
    }

    func testLivenessKeepsConnectionWithBufferedAsyncMessage() async throws {
        // A benign async message read into the buffer (NotificationResponse) must NOT discard the
        // connection — the reader consumes it next — matching isQuiescentOpen's plaintext A/N/S rule.
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }
        _ = try await connection.query("SELECT 1").rows

        await connection.primeReadBufferForTest(UInt8(ascii: "A"))   // a buffered NotificationResponse
        let alive = await connection.isProbablyAlive()
        XCTAssertTrue(alive, "a buffered async message must keep the connection alive, not discard it")
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
