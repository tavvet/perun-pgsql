import XCTest
@testable import PerunPGSQL

/// Live tests for the COPY sub-protocol: `copyOut` (server → client) streaming of raw
/// `CopyData`, including early termination leaving the connection reusable.
final class CopyIntegrationTests: XCTestCase {

    func testCopyOutMatchesTableData() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        _ = try await connection.query("CREATE TEMP TABLE copy_out_test (id int, name text)")
        _ = try await connection.query("INSERT INTO copy_out_test VALUES (1, 'alice'), (2, 'bob'), (3, 'carol')")

        var data: [UInt8] = []
        for try await chunk in try await connection.copyOut("COPY copy_out_test TO STDOUT") {
            data.append(contentsOf: chunk)
        }
        // Text COPY: tab-separated columns, newline-terminated rows.
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "1\talice\n2\tbob\n3\tcarol\n")

        // The connection is back in sync.
        let answer = try await connection.query("SELECT 7 AS a").rows[0].decode("a", as: Int.self)
        XCTAssertEqual(answer, 7)
    }

    func testCopyOutOfQuery() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        var data: [UInt8] = []
        for try await chunk in try await connection.copyOut("COPY (SELECT g FROM generate_series(1, 3) g) TO STDOUT") {
            data.append(contentsOf: chunk)
        }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "1\n2\n3\n")
    }

    func testCopyOutEarlyBreakLeavesConnectionUsable() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        _ = try await connection.query(
            "CREATE TEMP TABLE copy_out_big AS SELECT g AS id FROM generate_series(1, 100000) g")

        var chunks = 0
        for try await _ in try await connection.copyOut("COPY copy_out_big TO STDOUT") {
            chunks += 1
            if chunks == 3 { break }              // abandon the COPY early
        }
        XCTAssertEqual(chunks, 3)

        // The abandon path cancelled the COPY server-side and freed the wire.
        let answer = try await connection.query("SELECT 42 AS a").rows[0].decode("a", as: Int.self)
        XCTAssertEqual(answer, 42)
    }

    func testCopyOutRejectsNonCopyStatement() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        // A plain SELECT is not a COPY TO STDOUT.
        do {
            _ = try await connection.copyOut("SELECT 1")
            XCTFail("expected copyOut to reject a non-COPY statement")
        } catch {
            // expected
        }
        // Connection still usable.
        let answer = try await connection.query("SELECT 5 AS a").rows[0].decode("a", as: Int.self)
        XCTAssertEqual(answer, 5)
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
