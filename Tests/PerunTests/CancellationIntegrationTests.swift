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

        // Hold the wire lock with a slow query.
        let holder = Task { _ = try await connection.query("SELECT pg_sleep(0.5)") }
        try await Task.sleep(nanoseconds: 100_000_000)

        // A second query on the same connection has to park on the wire lock.
        let waiter = Task { try await connection.query("SELECT 1") }
        try await Task.sleep(nanoseconds: 60_000_000)
        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("a cancelled wire-lock waiter should throw")
        } catch is CancellationError {
            // expected
        }

        try await holder.value
        // The lock queue is clean and the connection is still usable.
        let n = try await connection.query("SELECT 1 AS n").rows[0].decode("n", as: Int.self)
        XCTAssertEqual(n, 1)
        try await connection.close()
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
