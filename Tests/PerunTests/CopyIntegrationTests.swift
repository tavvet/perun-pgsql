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

    // MARK: - COPY IN

    func testCopyInLoadsRows() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        _ = try await connection.query("CREATE TEMP TABLE copy_in_test (id int, name text)")
        let result = try await connection.copyIn("COPY copy_in_test FROM STDIN") { writer in
            try await writer.write("1\talice\n")
            try await writer.write("2\tbob\n3\tcarol\n")   // several rows in one chunk
        }
        XCTAssertEqual(result.commandTag, "COPY 3")

        let count = try await connection.query("SELECT count(*)::int AS c FROM copy_in_test")
            .rows[0].decode("c", as: Int.self)
        XCTAssertEqual(count, 3)
        let name = try await connection.query("SELECT name FROM copy_in_test WHERE id = 2")
            .rows[0].decode("name", as: String.self)
        XCTAssertEqual(name, "bob")
    }

    func testCopyInThenOutRoundTrip() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        _ = try await connection.query("CREATE TEMP TABLE copy_round (id int, name text)")
        try await connection.copyIn("COPY copy_round FROM STDIN") { writer in
            try await writer.write("10\tx\n20\ty\n")
        }
        var out: [UInt8] = []
        for try await chunk in try await connection.copyOut("COPY copy_round TO STDOUT") {
            out.append(contentsOf: chunk)
        }
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "10\tx\n20\ty\n")
    }

    func testCopyInAbortRollsBackAndConnectionUsable() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        _ = try await connection.query("CREATE TEMP TABLE copy_in_abort (id int)")
        struct Boom: Error {}
        do {
            try await connection.copyIn("COPY copy_in_abort FROM STDIN") { writer in
                try await writer.write("1\n")
                throw Boom()                       // abort after writing a row
            }
            XCTFail("expected the aborted copy to rethrow")
        } catch is Boom {
            // expected
        }

        // CopyFail rolled the copy back, so no rows landed…
        let count = try await connection.query("SELECT count(*)::int AS c FROM copy_in_abort")
            .rows[0].decode("c", as: Int.self)
        XCTAssertEqual(count, 0)
        // …and the connection is back in sync.
        let answer = try await connection.query("SELECT 9 AS a").rows[0].decode("a", as: Int.self)
        XCTAssertEqual(answer, 9)
    }

    func testCopyInWriterRejectedOutsideClosure() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        _ = try await connection.query("CREATE TEMP TABLE copy_in_leak (id int)")
        final class Box: @unchecked Sendable { var writer: PostgresCopyInWriter? }
        let box = Box()
        try await connection.copyIn("COPY copy_in_leak FROM STDIN") { writer in
            box.writer = writer
            try await writer.write("1\n")
        }
        // Using the writer after the copy finished is rejected, not silently corrupting the wire.
        do {
            try await box.writer?.write("2\n")
            XCTFail("expected a leaked writer to be rejected")
        } catch {
            // expected
        }
        let answer = try await connection.query("SELECT 3 AS a").rows[0].decode("a", as: Int.self)
        XCTAssertEqual(answer, 3)
    }

    // MARK: - Wrong-direction and stale-writer rejection

    func testCopyOutRejectsFromStdinWithoutHanging() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        _ = try await connection.query("CREATE TEMP TABLE copy_wrong_dir (id int)")
        // COPY FROM STDIN makes the server wait for client data; copyOut must abort it (CopyFail)
        // and throw rather than read on forever.
        do {
            _ = try await connection.copyOut("COPY copy_wrong_dir FROM STDIN")
            XCTFail("expected copyOut to reject a FROM STDIN statement")
        } catch {
            // expected
        }
        let answer = try await connection.query("SELECT 1 AS a").rows[0].decode("a", as: Int.self)
        XCTAssertEqual(answer, 1)
    }

    func testCopyInRejectsToStdout() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        // COPY TO STDOUT makes the server stream to us; copyIn must cancel/drain it and throw
        // without running the writer closure.
        do {
            try await connection.copyIn("COPY (SELECT 1) TO STDOUT") { _ in
                XCTFail("the writer closure should not run for a wrong-direction copyIn")
            }
            XCTFail("expected copyIn to reject a TO STDOUT statement")
        } catch {
            // expected
        }
        let answer = try await connection.query("SELECT 2 AS a").rows[0].decode("a", as: Int.self)
        XCTAssertEqual(answer, 2)
    }

    func testCopyInWriterRejectedDuringLaterCopy() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        _ = try await connection.query("CREATE TEMP TABLE copy_gen (id int)")
        final class Box: @unchecked Sendable { var writer: PostgresCopyInWriter? }
        let box = Box()

        try await connection.copyIn("COPY copy_gen FROM STDIN") { writer in
            box.writer = writer                    // leak the first copy's writer
            try await writer.write("1\n")
        }
        try await connection.copyIn("COPY copy_gen FROM STDIN") { writer in
            do {
                try await box.writer?.write("999\n")   // stale writer, different generation
                XCTFail("a stale writer must be rejected during a later copy")
            } catch {
                // expected — the generation guard rejects it
            }
            try await writer.write("2\n")          // the real writer still works
        }

        // Only 1 and 2 landed; the stale writer's 999 never reached the wire.
        let ids = try await connection.query("SELECT id FROM copy_gen ORDER BY id")
            .rows.map { try $0.decode("id", as: Int.self) }
        XCTAssertEqual(ids, [1, 2])
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
