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
