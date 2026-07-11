import XCTest
@testable import PerunPGSQL

/// End-to-end exercise of the TLS transport (handshake plus encrypted query I/O through the
/// memory BIOs). Runs only when pointed at a TLS-enabled server — set PGSSLMODE to a TLS mode
/// (e.g. `require`, `verify-full`) alongside PERUN_PGSQL_INTEGRATION=1. Skipped otherwise, so
/// the plaintext CI service doesn't fail it.
final class TLSIntegrationTests: XCTestCase {

    func testQueryRunsOverEncryptedConnection() async throws {
        let configuration = try integrationConfiguration()
        try XCTSkipUnless(configuration.tlsMode != .disable,
                          "set PGSSLMODE to a TLS mode to exercise the TLS transport")

        let connection = try await PostgresConnection.connect(configuration)
        do {
            let secure = await connection.isSecure
            XCTAssertTrue(secure, "the connection should be encrypted")

            // A few round trips exercise concurrent read/write over the one SSL object.
            for expected in 1 ... 5 {
                let value = try await connection
                    .query("SELECT \(expected)::int AS n")
                    .rows[0].decode("n", as: Int.self)
                XCTAssertEqual(value, expected)
            }
            try await connection.close()
        } catch {
            try? await connection.close()
            throw error
        }
    }

    func testIdleCheckSeesOpenSSLBufferedBytes() async throws {
        // The liveness probe peeks the raw socket, but over TLS the server's unsolicited bytes can
        // already be inside OpenSSL (decrypted, or ciphertext the last read pulled into the memory
        // read BIO) where a socket peek can't see them. Prime the read BIO to stand in for that and
        // confirm the connection is judged dead — a raw-socket-only probe would miss it.
        let configuration = try integrationConfiguration()
        try XCTSkipUnless(configuration.tlsMode != .disable,
                          "set PGSSLMODE to a TLS mode to exercise the TLS transport")

        let connection = try await PostgresConnection.connect(configuration)
        do {
            _ = try await connection.query("SELECT 1").rows          // reach steady state, drained to RFQ

            let aliveWhenDrained = await connection.isProbablyAlive()
            XCTAssertTrue(aliveWhenDrained, "a freshly drained TLS connection must look alive")

            let primed = await connection.primeTLSReadBufferForTest(8)
            XCTAssertTrue(primed, "expected a TLS connection to prime")

            let aliveWithBufferedBytes = await connection.isProbablyAlive()
            XCTAssertFalse(aliveWithBufferedBytes,
                           "bytes buffered inside OpenSSL must make the connection look dead, not alive")
            try await connection.close()
        } catch {
            try? await connection.close()
            throw error
        }
    }
}
