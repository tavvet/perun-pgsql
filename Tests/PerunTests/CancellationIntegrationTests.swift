import Foundation
import XCTest
@testable import PerunPGSQL

/// Cancelling a task parked for a pooled connection, or for the per-connection wire
/// lock, must fail that task with `CancellationError` and leave the pool / connection
/// usable — never orphan the waiter in its queue. Skipped unless
/// PERUN_PGSQL_INTEGRATION=1.
final class CancellationIntegrationTests: XCTestCase {

    func testPoolWaiterCancellationFailsAndKeepsPoolUsable() async throws {
        let pool = PostgresClient(configuration: try integrationConfiguration(), maxConnections: 1)

        // Occupy the single connection for a while.
        let holder = Task {
            try await pool.withConnection { connection in
                _ = try await connection.query("SELECT pg_sleep(0.5)")
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)   // let the holder check it out

        // This one has to park — the only connection is busy.
        let waiter = Task { try await pool.query("SELECT 1") }
        try await Task.sleep(nanoseconds: 60_000_000)    // let it park in the queue
        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("a cancelled pool waiter should throw")
        } catch is CancellationError {
            // expected: it left the queue instead of being handed a connection later
        }

        try await holder.value                           // holder finishes normally
        // The cancelled waiter left the queue clean, so the pool still hands out work.
        let n = try await pool.query("SELECT 1 AS n").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(n, 1)
        await pool.shutdown()
    }

    func testWireLockWaiterCancellationFailsAndKeepsConnectionUsable() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())

        // Hold the wire *exclusively* with a transaction (queries alone would pipeline).
        let holder = Task {
            try await connection.withTransaction { transaction in
                _ = try await transaction.query("SELECT pg_sleep(0.5)")
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        // A query on the same connection has to park behind the exclusive holder.
        let waiter = Task { try await connection.query("SELECT 1") }
        try await Task.sleep(nanoseconds: 60_000_000)
        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("a cancelled parked query should throw")
        } catch is CancellationError {
            // expected
        }

        try await holder.value
        // The access queue is clean and the connection is still usable.
        let n = try await connection.query("SELECT 1 AS n").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(n, 1)
        try await connection.close()
    }

    func testInFlightQueryCancellationStopsTheQuery() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())

        // A slow query that is the *sole* in-flight request, so CancelRequest is safe.
        let query = Task { try await connection.query("SELECT pg_sleep(5)") }
        try await Task.sleep(nanoseconds: 200_000_000)   // let it start running on the backend
        let start = Date()
        query.cancel()

        do {
            _ = try await query.value
            XCTFail("a cancelled in-flight query should throw")
        } catch is CancellationError {
            // expected
        }
        // CancelRequest actually stopped it server-side — nowhere near pg_sleep(5).
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)

        // The response drained cleanly, so the connection is still usable afterward.
        let alive = try await connection.query("SELECT 1 AS n").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(alive, 1)
        try await connection.close()
    }

    func testCopyInBlockedOnLockCancellationFreesTheWire() async throws {
        // copyIn's handshake read is cancellable: a COPY parked before CopyInResponse (here, waiting
        // on a table lock another session holds) must unblock on cancel — a CancelRequest aborts the
        // lock wait and the response drains — rather than holding the wire uninterruptibly.
        let setup = try await PostgresConnection.connect(integrationConfiguration())
        _ = try await setup.query("DROP TABLE IF EXISTS perun_copy_cancel")
        _ = try await setup.query("CREATE TABLE perun_copy_cancel (id int)")
        try await setup.close()

        // A second session takes an ACCESS EXCLUSIVE lock and keeps it, so the COPY below blocks.
        let holder = try await PostgresConnection.connect(integrationConfiguration())
        _ = try await holder.query("BEGIN")
        _ = try await holder.query("LOCK TABLE perun_copy_cancel IN ACCESS EXCLUSIVE MODE")

        let victim = try await PostgresConnection.connect(integrationConfiguration())
        let copy = Task {
            try await victim.copyIn("COPY perun_copy_cancel FROM STDIN") { writer in
                try await writer.write(Array("1\n".utf8))   // never reached: blocks before CopyInResponse
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)      // let the COPY park on the lock
        let start = Date()
        copy.cancel()
        do {
            _ = try await copy.value
            XCTFail("a cancelled copyIn blocked on a lock should throw")
        } catch is CancellationError {
            // expected: the CancelRequest aborted the lock wait and the response drained
        } catch let error as PerunError {
            // A late race can surface the server's own "canceling statement" error first; either way
            // the point is that it unblocked promptly, asserted below.
            _ = error
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.0, "the cancel must unblock the parked COPY promptly")

        // The victim drained to ReadyForQuery, so it stays usable.
        let n = try await victim.query("SELECT 1 AS n").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(n, 1)

        _ = try await holder.query("ROLLBACK")
        try await victim.close()
        try await holder.close()

        let cleanup = try await PostgresConnection.connect(integrationConfiguration())
        _ = try await cleanup.query("DROP TABLE IF EXISTS perun_copy_cancel")
        try await cleanup.close()
    }

    func testCopyInCancelledAtCopyModeTransitionTearsDown() async throws {
        // The race the lock test can't reach: a cancel that lands *after* CopyInResponse is read (the
        // server is in copy-in mode) but before copyIn marks the copy active. Abandoning the wire
        // there would desynchronise it; the fix tears the connection down. A test seam lets us hit
        // that window deterministically — the copyIn parks inside the handshake right after
        // CopyInResponse, we cancel, then release it — instead of racing cancel() against the wire.
        let setup = try await PostgresConnection.connect(integrationConfiguration())
        _ = try await setup.query("DROP TABLE IF EXISTS perun_copy_race")
        _ = try await setup.query("CREATE TABLE perun_copy_race (id int)")
        try await setup.close()

        let connection = try await PostgresConnection.connect(integrationConfiguration())
        let handshakeReached = Gate(), release = Gate()
        await connection.setCopyInHandshakeTestHook {
            await handshakeReached.open()    // CopyInResponse has been read — the server is in copy mode
            await release.wait()             // hold here until the test has cancelled
        }

        let task = Task {
            try await connection.copyIn("COPY perun_copy_race FROM STDIN") { writer in
                try await writer.write(Array("1\n".utf8))
            }
        }
        await handshakeReached.wait()        // now deterministically in the post-CopyInResponse window
        task.cancel()                        // observed at runInlineCancellable's isCancelled check
        await release.open()                 // let the handshake body return → onCancelledAfterSuccess runs

        do {
            _ = try await task.value
            XCTFail("a cancelled copyIn should throw")
        } catch is CancellationError {
            // expected
        }

        // The cancel landed after the copy-mode transition, so the driver must have torn the
        // connection down itself (onCancelledAfterSuccess) rather than hand back a desynced wire.
        let tornDown = await connection.releaseState.isClosed
        XCTAssertTrue(tornDown,
                      "a cancel after CopyInResponse must tear the connection down, not reuse it mid-COPY")

        // A follow-up therefore fails promptly as closed — it must not hang on a desynchronised wire.
        do {
            _ = try await withTimeout(.seconds(10)) { try await connection.query("SELECT 1").rows }
            XCTFail("the connection should have been torn down")
        } catch let error as PerunError {
            guard case .connectionClosed = error else {
                return XCTFail("expected connectionClosed after teardown, got \(error)")
            }
        }
        try? await connection.close()

        let cleanup = try await PostgresConnection.connect(integrationConfiguration())
        _ = try await cleanup.query("DROP TABLE IF EXISTS perun_copy_race")
        try await cleanup.close()
    }

    func testCopyOutTaskCancellationTearsDownWithoutCancelRequest() async throws {
        // A *cancelled* copyOut (unlike a plain break) must tear the connection down promptly — no
        // drain, no CancelRequest — so control returns at once and no stray cancel can leak. A test
        // seam parks nextCopyData right before a read so the cancel lands there deterministically.
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        _ = try await connection.query(
            "CREATE TEMP TABLE copy_cancel AS SELECT g AS id FROM generate_series(1, 100000) g")

        let reached = Gate(), release = Gate()
        await connection.setCopyOutBeforeReadTestHook {
            await reached.open()     // parked in nextCopyData, copy active, before a read
            await release.wait()
        }

        let task = Task {
            for try await _ in try await connection.copyOut("COPY copy_cancel TO STDOUT") {}
        }
        await reached.wait()
        task.cancel()
        await release.open()

        do {
            _ = try await task.value
            XCTFail("a cancelled copyOut should throw")
        } catch is CancellationError {
            // expected
        }

        let closed = await connection.releaseState.isClosed
        XCTAssertTrue(closed, "a cancelled copyOut must tear the connection down, not drain and keep it")

        // The connection is closed, so a follow-up fails promptly — it must not hang on a wire the
        // cancellation left mid-COPY.
        do {
            _ = try await withTimeout(.seconds(10)) { try await connection.query("SELECT 1").rows }
            XCTFail("the connection should have been torn down")
        } catch let error as PerunError {
            guard case .connectionClosed = error else {
                return XCTFail("expected connectionClosed, got \(error)")
            }
        }
        try? await connection.close()
    }

    func testCopyOutCancelledInLoopBodyTearsDownPromptly() async throws {
        // Prompt discard on cancel must also fire when the CancellationError comes from the for-await
        // *body* (the common case), not only when caught inside nextCopyData. There the iterator's
        // deinit drives teardown, so it must route on the Task.isCancelled it captures — else the
        // cancel is mistaken for a break and the connection drains (up to teardownResyncTimeout) instead.
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        _ = try await connection.query(
            "CREATE TEMP TABLE copy_body AS SELECT g AS id FROM generate_series(1, 100000) g")

        let inBody = Gate(), release = Gate()
        let task = Task {
            for try await _ in try await connection.copyOut("COPY copy_body TO STDOUT") {
                await inBody.open()          // holding a chunk, inside the loop body
                await release.wait()
                try Task.checkCancellation() // observe the cancel here, not in nextCopyData
            }
        }
        await inBody.wait()
        task.cancel()
        await release.open()

        do { _ = try await task.value; XCTFail("expected the cancelled copyOut to throw") }
        catch is CancellationError {}

        // The iterator's deinit tears the connection down in an unstructured task, so poll briefly.
        var closed = false
        for _ in 0 ..< 40 where !closed {
            closed = await connection.releaseState.isClosed
            if !closed { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        XCTAssertTrue(closed, "a copyOut cancelled in the loop body must tear the connection down promptly")
        try? await connection.close()
    }

    func testCloseStopsInlineStreamTeardownWatchdogBeforeFreeingFD() async throws {
        // Stream cancellation calls finishStream inline, while the driving iterator is still alive,
        // so there is no deinit-recorded teardown Task for close() to await. Park the bounded runner
        // after it arms its watchdog and prove close() stops the actor-registered watchdog anyway
        // before freeing the fd.
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        let readyToRead = Gate(), startRead = Gate()
        let teardownStarted = Gate(), releaseTeardown = Gate()
        await connection.setBoundedTeardownStartedTestHook {
            await teardownStarted.open()
            await releaseTeardown.wait()
        }

        let streaming = Task {
            var iterator = try await connection.queryStream("SELECT pg_sleep(3)").makeAsyncIterator()
            await readyToRead.open()
            await startRead.wait()
            _ = try await iterator.next()    // enters the already-cancelled fast path
        }
        await readyToRead.wait()
        streaming.cancel()
        await startRead.open()
        await teardownStarted.wait()

        do {
            try await connection.close()
        } catch {
            await releaseTeardown.open()
            _ = try? await streaming.value
            throw error
        }
        let watchdogCount = await connection.activeTeardownWatchdogCountForTest
        XCTAssertEqual(watchdogCount, 0,
                       "close() must stop every teardown watchdog before it frees the fd")

        await releaseTeardown.open()
        do {
            _ = try await streaming.value
            XCTFail("the cancelled stream should throw")
        } catch is CancellationError {
            // expected
        }
    }

    func testPoolDoesNotHandAWaiterAMidTeardownCopyOut() async throws {
        // A broken copyOut tears down in an unstructured Task; its wire stays held while it drains. The
        // pool's release must not hand that still-tearing-down connection to a queued waiter — the
        // waiter would park on the held lock and then fail as the teardown closes the socket. Drive
        // it deterministically: one pooled connection, held mid-copy, a waiter parked behind it, then
        // a break whose bounded drain (shortened via the seam) discards.
        let pool = PostgresClient(configuration: try integrationConfiguration(), maxConnections: 1)
        _ = try await pool.query("DROP TABLE IF EXISTS copy_pool_teardown")
        _ = try await pool.query(
            "CREATE TABLE copy_pool_teardown AS SELECT g AS id FROM generate_series(1, 2000000) g")

        let inCopy = Gate(), proceed = Gate()
        let holder = Task {
            try await pool.withConnection { conn in
                await conn.setTeardownResyncTimeout(.milliseconds(500))   // the remainder can't drain this fast → discard
                for try await _ in try await conn.copyOut("COPY copy_pool_teardown TO STDOUT") {
                    await inCopy.open()          // holding the pool's only connection, mid-copy
                    await proceed.wait()
                    break                        // abandon → teardown drains, then discards at 500 ms
                }
            }
        }
        await inCopy.wait()
        // A second borrower parks as a waiter (the one connection is held by `holder`).
        let waiter = Task {
            try await withTimeout(.seconds(3)) {
                try await pool.query("SELECT 7 AS n").rows[0].decode("n", as: Int.self)
            }
        }
        try await Task.sleep(nanoseconds: 200_000_000)   // let the waiter park
        await proceed.open()                             // holder breaks → release() decides the waiter's fate

        // With the fix, release discards the tearing-down connection and the pump serves the waiter a
        // fresh one, promptly. Without it, the waiter is handed the held connection, stalls on its
        // lock through the drain, then fails as it is closed (or times out on the stall).
        let answer = try await waiter.value
        XCTAssertEqual(answer, 7, "a waiter must be served a healthy connection, not a mid-teardown copyOut")

        try await holder.value
        _ = try await pool.query("DROP TABLE IF EXISTS copy_pool_teardown")
        await pool.shutdown()
    }

    // The hand-off (release / unlock) resumes a waiter asynchronously w.r.t.
    // cancellation, so a hand-off can win the race *after* a waiter is cancelled. A
    // waiter cancelled while parked must still fail — never run on the resource it was
    // handed. This loops to exercise that window; with the fix the cancelled waiter
    // always throws, whoever wins the hand-off. (Only the pool is tested this way: the
    // pool's `release()` is round-trip-free, so `resume(returning:)` genuinely races
    // the cancel. Releasing the wire lock always follows a query round-trip, which
    // lets `cancelLockWaiter` win first — so its hand-off branch isn't reachable from a
    // test. Its checkpoint is the identical pattern, covered by symmetry.)

    func testPoolWaiterCancelledDuringHandoffStillFails() async throws {
        let pool = PostgresClient(configuration: try integrationConfiguration(), maxConnections: 1)
        for _ in 0 ..< 15 {
            let holding = Gate(), release = Gate()
            let holder = Task {
                try await pool.withConnection { _ in
                    await holding.open()                     // signal: the only connection is now held
                    await release.wait()                     // keep holding until released
                }
            }
            await holding.wait()                             // start the waiter only once it's genuinely held

            let waiter = Task { try await pool.query("SELECT 1") }
            try await Task.sleep(nanoseconds: 20_000_000)    // let the waiter park in the queue
            waiter.cancel()
            await release.open()                             // release now: hand-off races the cancel

            do {
                _ = try await waiter.value
                XCTFail("a pool waiter cancelled while parked must throw, never run its query")
            } catch is CancellationError {
                // expected
            }
            try await holder.value
        }
        await pool.shutdown()
    }

}

/// A one-shot gate: holders `wait()` until someone `open()`s it. Lets a test hold a
/// pooled connection / the wire lock until it deliberately releases, so the release
/// and a cancel can be made to race.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
