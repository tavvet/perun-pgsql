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

    func testHeldStreamSequenceFreesWireOnBreak() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        // Hold the SEQUENCE in a variable (not a temporary): breaking the loop drops the iterator,
        // and the wire must be freed even though `stream` is still retained. Cleanup is owned by
        // the iterator, so this works; if the sequence held it, the query below would hang.
        let stream = try await connection.queryStream(
            "SELECT g FROM generate_series(1, 100000) g", chunkSize: 10)
        var seen = 0
        for try await _ in stream {
            seen += 1
            if seen == 5 { break }
        }
        XCTAssertEqual(seen, 5)

        let answer = try await connection.query("SELECT 42 AS a").rows[0].decode("a", as: Int.self)
        XCTAssertEqual(answer, 42)
        withExtendedLifetime(stream) {}          // keep the sequence alive past the query above
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

    func testCancellationWhileWaitingFreesConnectionPromptly() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        // The first row only arrives after pg_sleep, so the stream blocks in the read.
        let streaming = Task {
            for try await _ in try await connection.queryStream("SELECT pg_sleep(3)") {}
        }
        try await Task.sleep(nanoseconds: 300_000_000)     // let it reach the blocking read

        let clock = ContinuousClock()
        let start = clock.now
        streaming.cancel()

        var cancelled = false
        do { try await streaming.value } catch is CancellationError { cancelled = true } catch { }
        let elapsed = clock.now - start

        // A CancelRequest aborts the sleep, so this returns in well under the 3s the query
        // would otherwise take — not after it.
        XCTAssertTrue(cancelled, "a cancelled stream should throw CancellationError")
        XCTAssertLessThan(elapsed, .seconds(2), "cancellation should be prompt, not wait for pg_sleep")

        // The wire was freed, so the connection is immediately reusable.
        let answer = try await connection.query("SELECT 42 AS a").rows[0].decode("a", as: Int.self)
        XCTAssertEqual(answer, 42)
    }

    func testCancellationBeforeFirstReadFreesConnectionPromptly() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        let clock = ContinuousClock()
        let start = clock.now
        // Cancel immediately: the exclusive lock is free, so queryStream still sends the query,
        // and the first read finds the task already cancelled (the pre-read fast path).
        let streaming = Task {
            for try await _ in try await connection.queryStream("SELECT pg_sleep(3)") {}
        }
        streaming.cancel()

        var cancelled = false
        do { try await streaming.value } catch is CancellationError { cancelled = true } catch { }
        let elapsed = clock.now - start

        XCTAssertTrue(cancelled, "a stream cancelled before its first read should throw CancellationError")
        XCTAssertLessThan(elapsed, .seconds(2), "the pre-read cancel path must abort the query, not wait for pg_sleep")

        let answer = try await connection.query("SELECT 42 AS a").rows[0].decode("a", as: Int.self)
        XCTAssertEqual(answer, 42)
    }

    func testStaleStreamDeinitDoesNotDisturbANewerStream() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        // Consume stream A to completion but keep its iterator alive, so A's AbandonedSequenceCleanup
        // deinit — which enqueues the stale finishStream — has not run yet.
        var iteratorA: PostgresRowStream.AsyncIterator? =
            try await connection.queryStream("SELECT g FROM generate_series(1, 10) g").makeAsyncIterator()
        var aRows = 0
        while let row = try await iteratorA!.next() { _ = try row.decode("g", as: Int.self); aRows += 1 }
        XCTAssertEqual(aRows, 10)                       // A fully consumed; endStream freed the wire

        // Start stream B on the same connection and pull one row so it owns the wire.
        var iteratorB = try await connection.queryStream(
            "SELECT g FROM generate_series(1, 10) g").makeAsyncIterator()
        let firstB = try await iteratorB.next()         // B is active; the generation is now B's
        XCTAssertNotNil(firstB)

        // Drop A's iterator → AbandonedSequenceCleanup deinit → finishStream(generation: A) while B is live.
        // The generation guard must make it a no-op; without it, it closes B's portal and steals rows.
        iteratorA = nil
        try await Task.sleep(for: .milliseconds(50))    // give the deinit's Task time to run

        // B must still deliver its remaining rows intact.
        var bRows = 1
        while let row = try await iteratorB.next() { _ = try row.decode("g", as: Int.self); bRows += 1 }
        XCTAssertEqual(bRows, 10, "a stale deinit of stream A must not disturb the newer stream B")
    }

    func testCloseDuringActiveStreamDoesNotHangLaterQueries() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())

        // Open a stream and pull one row so it holds the wire exclusively (exclusiveHeld == true).
        var iterator = try await connection.queryStream(
            "SELECT g FROM generate_series(1, 1000) g", chunkSize: 10).makeAsyncIterator()
        let firstRow = try await iterator.next()
        XCTAssertNotNil(firstRow)

        // Force-close while the stream still holds the exclusive lock: forceClose can't unlock it,
        // so the lock state is frozen. A later acquirer must see `isClosed` and fail fast rather
        // than park on a hold nothing will ever release.
        try await connection.close()

        // Wrap in a timeout so the old permanent-hang regression fails the test instead of stalling
        // the whole suite: the fix yields a prompt .connectionClosed, a regression a .timedOut.
        var thrown: Error?
        do { _ = try await withTimeout(.seconds(5)) { try await connection.query("SELECT 1") } }
        catch { thrown = error }
        withExtendedLifetime(iterator) {}   // the stream held the wire across the close()+query() above

        guard let perun = thrown as? PerunError, case .connectionClosed = perun else {
            return XCTFail("expected a prompt .connectionClosed, got \(String(describing: thrown)) — a hang/timeout means the exclusive lock was stuck")
        }
    }

    // MARK: - Helpers

}
