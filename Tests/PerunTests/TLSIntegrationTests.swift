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
}
