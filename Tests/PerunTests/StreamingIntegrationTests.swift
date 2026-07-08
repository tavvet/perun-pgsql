import XCTest
@testable import PerunPGSQL

/// Live tests for `queryStream`: chunked portal fetch, parameters, early termination, and
/// mid-stream errors — each also checks the connection is reusable afterwards.
final class StreamingIntegrationTests: XCTestCase {

    func testStreamMatchesBufferedResult() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        // 1000 rows over a chunk size of 100 forces the PortalSuspended path ten times.
        var streamed: [Int] = []
        for try await row in try await connection.queryStream(
            "SELECT g FROM generate_series(1, 1000) g", chunkSize: 100) {
            streamed.append(try row.decode("g", as: Int.self))
        }
        XCTAssertEqual(streamed, Array(1...1000))
    }

    func testStreamWithParametersAndTinyChunks() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        // chunkSize 1 = one round trip per row, stressing the chunk loop.
        var streamed: [Int] = []
        for try await row in try await connection.queryStream(
            "SELECT g FROM generate_series($1::int, $2::int) g", [3, 7], chunkSize: 1) {
            streamed.append(try row.decode("g", as: Int.self))
        }
        XCTAssertEqual(streamed, [3, 4, 5, 6, 7])
    }

    func testStreamEmptyResult() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        var count = 0
        for try await _ in try await connection.queryStream("SELECT g FROM generate_series(1, 0) g") {
            count += 1
        }
        XCTAssertEqual(count, 0)
        // Still usable.
        let answer = try await connection.query("SELECT 1 AS a").rows[0].decode("a", as: Int.self)
        XCTAssertEqual(answer, 1)
    }

    func testEarlyBreakLeavesConnectionUsable() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        var seen = 0
        for try await _ in try await connection.queryStream(
            "SELECT g FROM generate_series(1, 100000) g", chunkSize: 10) {
            seen += 1
            if seen == 5 { break }               // abandon the stream early
        }
        XCTAssertEqual(seen, 5)

        // The stream's cleanup closed the portal and freed the wire, so a new query runs.
        let answer = try await connection.query("SELECT 42 AS a").rows[0].decode("a", as: Int.self)
        XCTAssertEqual(answer, 42)
    }

    func testMidStreamErrorSurfacesAndConnectionUsable() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        var thrown: Error?
        var rowsBeforeError = 0
        do {
            // Divides by zero at g = 3, after streaming a couple of rows.
            for try await _ in try await connection.queryStream(
                "SELECT 1 / (g - 3) FROM generate_series(1, 5) g", chunkSize: 1) {
                rowsBeforeError += 1
            }
        } catch {
            thrown = error
        }
        XCTAssertNotNil(thrown, "a mid-stream server error should surface")
        XCTAssertGreaterThan(rowsBeforeError, 0, "some rows should arrive before the error")

        // The error was drained to ReadyForQuery, so the connection is back in sync.
        let answer = try await connection.query("SELECT 7 AS a").rows[0].decode("a", as: Int.self)
        XCTAssertEqual(answer, 7)
    }

    // MARK: - Helpers

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
