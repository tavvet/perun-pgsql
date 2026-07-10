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

        // The abandon path drained the small remainder and freed the wire — connection reusable.
        let answer = try await connection.query("SELECT 42 AS a").rows[0].decode("a", as: Int.self)
        XCTAssertEqual(answer, 42)
    }

    func testCopyOutEarlyBreakOnHugeStreamClosesRatherThanHangs() async throws {
        var configuration = try integrationConfiguration()
        configuration.copyResyncTimeout = .milliseconds(200)   // bound the abandon-drain tightly
        let connection = try await PostgresConnection.connect(configuration)
        defer { Task { try? await connection.close() } }

        _ = try await connection.query(
            "CREATE TEMP TABLE copy_out_huge AS SELECT g AS id FROM generate_series(1, 50000000) g")

        // Break early on a huge stream: the abandon path (finishCopyOut) can't drain the ~50M-row
        // remainder within the tiny resync timeout, so it must close the connection — NOT fire an
        // async CancelRequest (which could hit the next statement) and NOT hold the wire for the
        // whole dump.
        var chunks = 0
        for try await _ in try await connection.copyOut("COPY copy_out_huge TO STDOUT") {
            chunks += 1
            if chunks == 3 { break }
        }
        XCTAssertEqual(chunks, 3)

        // The next query waits on the wire lock the abandon path holds, then fails fast when it
        // closes — it must not hang for the whole 50M-row stream.
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await connection.query("SELECT 1")
            XCTFail("expected the connection to be closed after abandoning a huge COPY OUT")
        } catch let error as PerunError {
            guard case .connectionClosed = error else {
                return XCTFail("expected .connectionClosed, got \(error)")
            }
        }
        XCTAssertLessThan(clock.now - start, .seconds(5),
                          "abandoning a huge COPY OUT must close quickly, not drain the whole stream")
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

    func testWrongDirectionCopyKeepsPooledConnection() async throws {
        let pool = PostgresClient(configuration: try integrationConfiguration(), maxConnections: 1)
        defer { Task { await pool.shutdown() } }

        _ = try await pool.query("SELECT 1")            // open one connection, return it to the pool
        let before = await pool.connectionCount
        XCTAssertEqual(before, 1)

        // copyOut on a non-COPY statement drains the wire to ReadyForQuery, so the connection stays
        // in sync — the pool must keep it, not discard and reopen (which .protocolViolation forced).
        do {
            try await pool.withConnection { connection in _ = try await connection.copyOut("SELECT 1") }
            XCTFail("expected copyOut to reject a non-COPY statement")
        } catch {
            // expected — a copyMismatch, which leaves the connection reusable
        }
        let after = await pool.connectionCount
        XCTAssertEqual(after, before, "a wire-synced COPY misuse must not churn the pooled connection")
    }

    func testCopyInWrongDirectionDoesNotLeakCancelToTheNextQuery() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        // A wrong-direction copyIn (a COPY … TO STDOUT) must reject WITHOUT firing a stray
        // CancelRequest: an async cancel can outlive a short COPY and then cancel the *next*
        // statement on this connection (SQLSTATE 57014). Loop to stress the timing the old
        // cancel-based path raced on — every follow-up query must succeed.
        for i in 1 ... 25 {
            do {
                try await connection.copyIn("COPY (SELECT \(i)) TO STDOUT") { _ in
                    XCTFail("the writer closure must not run for a wrong-direction copyIn")
                }
                XCTFail("expected copyIn to reject a TO STDOUT statement")
            } catch let error as PerunError {
                guard case .copyMismatch = error else {
                    return XCTFail("expected .copyMismatch, got \(error)")
                }
            }
            let value = try await connection.query("SELECT \(i) AS a").rows[0].decode("a", as: Int.self)
            XCTAssertEqual(value, i, "the query after a rejected copyIn must not be hit by a stray cancel")
        }
    }

    func testWrongDirectionCopyInGivesUpAndClosesOnAnUnboundedCopy() async throws {
        var configuration = try integrationConfiguration()
        configuration.copyResyncTimeout = .milliseconds(200)   // bound the resync tightly for the test
        let connection = try await PostgresConnection.connect(configuration)
        defer { Task { try? await connection.close() } }

        // A physical table streams `CopyOutResponse` immediately and then a long run of rows (a
        // subquery like `generate_series` would instead be materialised *before* CopyOutResponse, so
        // its wait wouldn't exercise the drain). Far more rows than the tiny resync timeout can drain.
        _ = try await connection.query(
            "CREATE TEMP TABLE perun_copy_stress AS SELECT g FROM generate_series(1, 50000000) g")

        // The wrong-direction copyIn must give up on the drain within ~copyResyncTimeout and close
        // the connection, not hold the wire (and its exclusive lock) for the whole 50M-row stream.
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await connection.copyIn("COPY perun_copy_stress TO STDOUT") { _ in
                XCTFail("the writer closure must not run for a wrong-direction copyIn")
            }
            XCTFail("expected copyIn to reject a TO STDOUT statement")
        } catch let error as PerunError {
            guard case .copyMismatch = error else {
                return XCTFail("expected .copyMismatch, got \(error)")
            }
        }
        XCTAssertLessThan(clock.now - start, .seconds(5),
                          "the bounded resync must give up quickly, not drain the whole COPY")

        // Escaping the unbounded drain meant closing the connection — it must not be reusable.
        do {
            _ = try await connection.query("SELECT 1")
            XCTFail("expected the connection to be closed after the bounded resync gave up")
        } catch let error as PerunError {
            guard case .connectionClosed = error else {
                return XCTFail("expected .connectionClosed, got \(error)")
            }
        }
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
