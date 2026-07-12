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
            "CREATE TEMP TABLE copy_out_big AS SELECT g AS id FROM generate_series(1, 10000) g")

        var chunks = 0
        for try await _ in try await connection.copyOut("COPY copy_out_big TO STDOUT") {
            chunks += 1
            if chunks == 3 { break }              // abandon the COPY early
        }
        XCTAssertEqual(chunks, 3)

        // The break drained the (small) remainder well within copyResyncTimeout and freed the wire —
        // no CancelRequest — so the connection stays usable.
        let answer = try await connection.query("SELECT 42 AS a").rows[0].decode("a", as: Int.self)
        XCTAssertEqual(answer, 42)
    }

    func testBrokenCopyOutDoesNotCancelTheNextQuery() async throws {
        // Breaking out of a copyOut must fire no CancelRequest. A CancelRequest is async and
        // per-backend: with a tiny relation the COPY finishes streaming before the cancel's socket
        // even connects, so the stray cancel lands on whatever runs next — here a pg_sleep, which
        // gives it a wide window to strike (a spurious 57014). With the fix (drain, no cancel) the
        // follow-up query runs untouched.
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }
        _ = try await connection.query(
            "CREATE TEMP TABLE copy_leak AS SELECT g AS id FROM generate_series(1, 5) g")

        var chunks = 0
        for try await _ in try await connection.copyOut("COPY copy_leak TO STDOUT") {
            chunks += 1
            if chunks == 1 { break }
        }
        // A slow statement the stray cancel would strike if the break fired one.
        let n = try await connection.query("SELECT 7 AS n FROM pg_sleep(1)").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(n, 7, "a broken copyOut leaked a CancelRequest onto the next query")
    }

    func testCopyOutBreakOnHugeStreamClosesRatherThanDrainingItAll() async throws {
        // A physical table streams CopyData immediately after CopyOutResponse (a generate_series
        // subquery would materialize first), so a remainder too large to drain within the resync
        // timeout must close+discard the connection rather than read the whole relation.
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }
        await connection.setCopyResyncTimeout(.milliseconds(50))
        _ = try await connection.query(
            "CREATE TEMP TABLE copy_huge AS SELECT g AS id FROM generate_series(1, 2000000) g")

        var chunks = 0
        for try await _ in try await connection.copyOut("COPY copy_huge TO STDOUT") {
            chunks += 1
            if chunks == 3 { break }
        }

        // The break gave up on the huge remainder and tore the connection down, so a follow-up fails
        // promptly as closed — it must not hang draining millions of rows.
        do {
            _ = try await withTimeout(.seconds(5)) { try await connection.query("SELECT 1").rows }
            XCTFail("expected the connection closed after abandoning a huge copyOut")
        } catch let error as PerunError {
            guard case .connectionClosed = error else {
                return XCTFail("expected connectionClosed, got \(error)")
            }
        }
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

        // COPY TO STDOUT makes the server stream to us. A COPY-out can't be stopped in band and
        // could block/stream unboundedly, so copyIn tears the connection down (without running the
        // writer closure) rather than draining or firing a racy cancel.
        do {
            try await connection.copyIn("COPY (SELECT 1) TO STDOUT") { _ in
                XCTFail("the writer closure should not run for a wrong-direction copyIn")
            }
            XCTFail("expected copyIn to reject a TO STDOUT statement")
        } catch {
            // expected
        }
        // The connection was closed to avoid an unbounded drain, so a further query must fail.
        do {
            _ = try await connection.query("SELECT 2 AS a")
            XCTFail("the connection should have been closed after the wrong-direction copyIn")
        } catch {
            // expected
        }
    }

    func testQueryRejectsCopyToStdoutAndClosesConnection() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        // COPY … TO STDOUT via query() must be rejected; the connection is torn down (a COPY-out
        // can't be stopped in band) rather than drained or cancelled.
        do {
            _ = try await connection.query("COPY (SELECT 1) TO STDOUT")
            XCTFail("expected query() to reject a COPY … TO STDOUT")
        } catch let error as PerunError {
            guard case .copyMismatch = error else {
                return XCTFail("expected .copyMismatch, got \(error)")
            }
        }
        do {
            _ = try await connection.query("SELECT 1")
            XCTFail("connection should be closed after the COPY … TO STDOUT misuse")
        } catch {
            // expected
        }
    }

    func testQueryRejectsHugeCopyToStdoutWithoutDraining() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        // A fast-starting huge stream: CopyOutResponse arrives promptly, so the connection is
        // torn down at once instead of draining tens of millions of rows (the reason we close
        // rather than drain). A slow-to-first-row COPY would instead block like any slow query,
        // bounded by task cancellation / withTimeout — that's not what this checks.
        let start = ContinuousClock().now
        do {
            _ = try await connection.query("COPY (SELECT generate_series(1, 50000000)) TO STDOUT")
            XCTFail("expected .copyMismatch")
        } catch let error as PerunError {
            guard case .copyMismatch = error else {
                return XCTFail("expected .copyMismatch, got \(error)")
            }
        }
        XCTAssertLessThan(ContinuousClock().now - start, .seconds(3),
                          "the misuse must be rejected without draining the stream")
    }

    func testPoolRecoversAfterCopyToStdoutMisuse() async throws {
        let pool = PostgresClient(configuration: try integrationConfiguration(), maxConnections: 2)
        defer { Task { await pool.shutdown() } }

        // The torn-down connection must be discarded, not returned to the pool or handed to a waiter.
        do {
            _ = try await pool.query("COPY (SELECT 1) TO STDOUT")
            XCTFail("expected .copyMismatch")
        } catch let error as PerunError {
            guard case .copyMismatch = error else {
                return XCTFail("expected .copyMismatch, got \(error)")
            }
        }
        // The pool still serves queries on a fresh connection.
        let answer = try await pool.query("SELECT 42 AS a").rows[0].decode("a", as: Int.self)
        XCTAssertEqual(answer, 42)
    }

    func testExtendedQueryRejectsCopyFromStdin() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        _ = try await connection.query("CREATE TEMP TABLE copy_ext (id int)")
        // A binary result forces the extended protocol (Parse/Bind/Execute/Sync). A CopyFail
        // can't resynchronise that path (the pre-sent Sync is consumed during COPY), so the misuse
        // must tear the connection down promptly rather than hang waiting for a Sync that never comes.
        let start = ContinuousClock().now
        do {
            _ = try await connection.query("COPY copy_ext FROM STDIN", [], resultFormat: .binary)
            XCTFail("expected query() to reject a COPY … FROM STDIN")
        } catch let error as PerunError {
            guard case .copyMismatch = error else {
                return XCTFail("expected .copyMismatch, got \(error)")
            }
        }
        XCTAssertLessThan(ContinuousClock().now - start, .seconds(4), "the misuse must not hang")
        do {
            _ = try await connection.query("SELECT 1")
            XCTFail("connection should be closed after the COPY … FROM STDIN misuse")
        } catch {
            // expected
        }
    }

    func testQueryStreamRejectsCopy() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        // queryStream isn't for COPY: TO STDOUT would silently stream the whole relation. The
        // stream must reject it promptly and tear the connection down.
        let start = ContinuousClock().now
        do {
            for try await _ in try await connection.queryStream("COPY (SELECT 1) TO STDOUT") {
                XCTFail("no rows should stream from a COPY")
            }
            XCTFail("expected queryStream to reject a COPY")
        } catch let error as PerunError {
            guard case .copyMismatch = error else {
                return XCTFail("expected .copyMismatch, got \(error)")
            }
        }
        XCTAssertLessThan(ContinuousClock().now - start, .seconds(4), "the misuse must not hang")
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

    func testCloseWaitsForAnInFlightTeardown() async throws {
        // close() must let an abandoned copyOut/stream's detached teardown settle before it frees the
        // fd — the teardown's watchdog captured this fd, and freeing it mid-teardown could let that
        // watchdog shut down a descriptor the OS has since reused. The fd-reuse race can't be provoked
        // deterministically, so we test the mechanism directly: record a still-running teardown (the
        // same handle a break's deinit records) and assert close() blocks until it settles rather than
        // racing it. Without the await, close() returns near-instantly.
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        connection.recordCopyOutTeardown(
            generation: 1, task: Task { try? await Task.sleep(for: .milliseconds(300)) })

        let start = ContinuousClock().now
        try await connection.close()
        let elapsed = ContinuousClock().now - start
        XCTAssertGreaterThan(elapsed, .milliseconds(150),
                             "close() must wait for the in-flight teardown to settle before freeing the fd")
    }

    // MARK: - Helpers

}
