import XCTest
@testable import PerunPGSQL

/// Live tests for `PostgresClient`'s validate-on-borrow: a healthy idle connection is
/// reused, but one the server closed while idle is detected, discarded, and replaced —
/// rather than handed to a borrower whose first query would fail.
final class PoolValidationIntegrationTests: XCTestCase {

    func testHealthyIdleConnectionIsReused() async throws {
        let pool = PostgresClient(configuration: try integrationConfiguration(), maxConnections: 1)

        let pid1 = try await pool.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)
        let pid2 = try await pool.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)
        // The liveness probe must not false-positive: the same backend is reused.
        XCTAssertEqual(pid1, pid2, "a healthy idle connection should be reused, not discarded")

        await pool.shutdown()
    }

    func testLivenessCheckSeesDriverBufferedBytes() async throws {
        // readSlice reads ahead, so a read can leave a trailing message in the driver's own readBuffer
        // that the socket and OpenSSL peeks can't see. A pooled connection carrying a buffered
        // termination/error must be judged dead — otherwise the next borrower gets a stale wire.
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }
        _ = try await connection.query("SELECT 1").rows          // steady state, drained to RFQ

        let aliveWhenDrained = await connection.isProbablyAlive()
        XCTAssertTrue(aliveWhenDrained, "a freshly drained connection must look alive")

        await connection.primeReadBufferForTest([UInt8(ascii: "E")])   // a buffered ErrorResponse (termination)
        let aliveWithBuffered = await connection.isProbablyAlive()
        XCTAssertFalse(aliveWithBuffered,
                       "a buffered non-async message must make the connection look dead")
    }

    func testLivenessSeesAnErrorHiddenBehindAnAsyncMessage() async throws {
        // Read-ahead can pull several frames into readBuffer at once. A benign async 'A' first, then a
        // termination 'E', must NOT read as alive just because the first tag is benign — the walk has
        // to reach the 'E' behind it, or the next borrower inherits a dead wire.
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }
        _ = try await connection.query("SELECT 1").rows

        await connection.primeReadBufferRawForTest(notificationFrame() + [UInt8(ascii: "E"), 0, 0, 0, 4])
        let alive = await connection.isProbablyAlive()
        XCTAssertFalse(alive, "an 'E' buffered behind a benign 'A' must still make the connection look dead")
    }

    func testLivenessRejectsAMalformedAsyncFrameLengthHidingAnError() async throws {
        // The walk must validate the frame length like the framing decoder: a garbage length (0xFFFFFFFF,
        // a negative Int32) must read as a desync, not a benign "incomplete" frame — otherwise a
        // termination 'E' queued right behind such an 'A' hides and the connection looks alive.
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }
        _ = try await connection.query("SELECT 1").rows

        // 'A' with length 0xFFFFFFFF (a negative Int32), then a well-formed empty 'E' behind it.
        await connection.primeReadBufferRawForTest([UInt8(ascii: "A"), 0xFF, 0xFF, 0xFF, 0xFF,
                                                    UInt8(ascii: "E"), 0, 0, 0, 4])
        let alive = await connection.isProbablyAlive()
        XCTAssertFalse(alive, "a malformed async frame length must read as dead, not hide the 'E' behind it")
    }

    func testLivenessKeepsConnectionWithBufferedAsyncMessage() async throws {
        // A benign async message the driver already read into readBuffer (NotificationResponse) must NOT
        // discard the connection — the frame walk classifies it and the reader consumes it next.
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }
        _ = try await connection.query("SELECT 1").rows

        await connection.primeReadBufferRawForTest(notificationFrame())   // a real, decodable NotificationResponse
        let alive = await connection.isProbablyAlive()
        XCTAssertTrue(alive, "a buffered async message must keep the connection alive, not discard it")
    }

    func testLivenessDiscardsAKernelBufferedMessageBehindTheSocket() async throws {
        // Same shadow as the readBuffer walk, one layer down: a NotificationResponse 'A' followed by a
        // termination 'E' sitting in the *kernel* buffer (readBuffer empty, no reader consuming). A raw
        // one-byte peek sees the benign 'A' and can't see the 'E' behind it, so the probe must treat any
        // pending kernel data as suspect and read the connection as dead.
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }
        let pid = try await connection.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)
        _ = try await connection.query("LISTEN perun_liveness_chan").rows   // so a NOTIFY reaches this backend

        let other = try await PostgresConnection.connect(integrationConfiguration())
        _ = try await other.query("NOTIFY perun_liveness_chan, 'x'").rows   // 'A' lands in this socket's kernel buffer
        try await Task.sleep(nanoseconds: 100_000_000)                      // let the 'A' land before the 'E'
        _ = try await other.query("SELECT pg_terminate_backend(\(pid))").rows   // 'E' + close land behind it
        try await other.close()
        try await Task.sleep(nanoseconds: 300_000_000)                      // let both settle in the kernel buffer

        let alive = await connection.isProbablyAlive()
        XCTAssertFalse(alive, "a kernel-buffered async message shadowing a termination must read as dead")
    }

    func testLivenessRejectsAMalformedAsyncPayloadThatTheDecoderWouldReject() async throws {
        // A frame can pass framing yet be rejected by the message decoder: an 'A' with a valid length but
        // an empty payload is no real NotificationResponse (no PID, no strings). The probe must run each
        // full frame through the same decoder the reader uses, or it keeps a connection whose very next
        // read is a protocol violation.
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }
        _ = try await connection.query("SELECT 1").rows

        await connection.primeReadBufferForTest([UInt8(ascii: "A")])   // 'A', length 4, empty payload — malformed
        let alive = await connection.isProbablyAlive()
        XCTAssertFalse(alive, "a framing-valid but undecodable async frame must read as dead")
    }

    func testPooledCopyOutBreakWithCheapRemainderKeepsTheConnection() async throws {
        // Breaking out of a pooled copyOut with a cheap remainder must KEEP the connection (the bounded
        // drain resyncs it), not churn it. release() has to await the teardown instead of racing it: its
        // local actor hop otherwise beats the network drain and discards a connection the drain was about
        // to keep, forcing a fresh TLS/SCRAM handshake. Same backend PID before and after proves reuse.
        let pool = PostgresClient(configuration: try integrationConfiguration(), maxConnections: 1)

        let pid0 = try await pool.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)

        // A per-row pg_sleep makes the remainder take ~0.15s to drain — long enough that release() would
        // win the race and discard without the fix, yet far under the 5s resync timeout so it is kept.
        try await pool.withConnection { connection in
            for try await _ in try await connection.copyOut(
                "COPY (SELECT g, pg_sleep(0.05) FROM generate_series(1, 4) g) TO STDOUT") {
                break                                   // stop after the first chunk; 3 rows still to come
            }
        }

        let pid1 = try await pool.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)
        XCTAssertEqual(pid1, pid0, "a cheap-remainder break must keep the pooled connection, not churn it")

        await pool.shutdown()
    }

    func testPooledStreamBreakWithCheapRemainderKeepsTheConnection() async throws {
        // A broken queryStream tears down in a detached Task (finishStream) exactly like copyOut, so the
        // pool must await it before judging the connection — otherwise release()'s local hop beats the
        // drain, reads the stream still active, and discards a connection the cheap drain would keep.
        // Same backend PID before and after proves reuse.
        let pool = PostgresClient(configuration: try integrationConfiguration(), maxConnections: 1)

        let pid0 = try await pool.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)

        // chunkSize (512) covers all rows in one Execute, so breaking after the first leaves the rest
        // still trickling in behind a per-row pg_sleep — a cheap-but-slow remainder for finishStream.
        try await pool.withConnection { connection in
            for try await _ in try await connection.queryStream(
                "SELECT g, pg_sleep(0.05) FROM generate_series(1, 4) g") {
                break
            }
        }

        let pid1 = try await pool.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)
        XCTAssertEqual(pid1, pid0, "a cheap-remainder stream break must keep the pooled connection, not churn it")

        await pool.shutdown()
    }

    func testStaleCopyIteratorDeinitDoesNotClobberANewerTeardown() async throws {
        // The teardown box is one slot. A stale iterator held past its copy, dropped after a newer copy
        // recorded its real drain task, must NOT overwrite that handle with its own (generation-guarded
        // no-op) task — or release() awaits the no-op, samples the wire mid-drain, and discards a
        // connection the cheap drain was about to keep. Same-PID reuse proves the newer teardown won.
        let pool = PostgresClient(configuration: try integrationConfiguration(), maxConnections: 1)

        let pid0 = try await pool.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)

        try await pool.withConnection { connection in
            // Copy 1 (older generation): consume it fully via a manually held iterator.
            var iterator = try await connection.copyOut("COPY (SELECT 1) TO STDOUT").makeAsyncIterator()
            while try await iterator.next() != nil {}
            // Copy 2 (newer generation): break with a cheap-but-slow (pg_sleep) remainder — records its
            // real drain task.
            for try await _ in try await connection.copyOut(
                "COPY (SELECT g, pg_sleep(0.05) FROM generate_series(1, 4) g) TO STDOUT") {
                break
            }
            // Keep copy 1's iterator alive until *after* copy 2 recorded, so its deinit (a stale-generation
            // no-op) fires last and must not clobber copy 2's teardown handle.
            _ = iterator
        }

        let pid1 = try await pool.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)
        XCTAssertEqual(pid1, pid0, "a stale iterator's late deinit must not clobber the newer teardown and churn the connection")

        await pool.shutdown()
    }

    func testTerminatedIdleConnectionIsReplaced() async throws {
        let configuration = try integrationConfiguration()
        let pool = PostgresClient(configuration: configuration, maxConnections: 1)

        // Open the pool's one connection and note its backend, then return it to idle.
        let pid = try await pool.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)

        // Terminate that backend from a separate connection; the server sends a termination
        // error and closes the socket the pool is holding idle.
        let killer = try await PostgresConnection.connect(configuration)
        _ = try await killer.query("SELECT pg_terminate_backend(\(pid))")
        try await killer.close()

        // Give the server a moment to deliver the termination and close.
        try await Task.sleep(nanoseconds: 300_000_000)

        // The pool must validate, discard the dead connection, and open a fresh one — the
        // borrower's query succeeds on a new backend rather than failing.
        let pid2 = try await pool.query("SELECT pg_backend_pid() AS p").rows[0].decode("p", as: Int.self)
        XCTAssertNotEqual(pid2, pid, "the terminated connection should have been replaced")

        await pool.shutdown()
    }

    // MARK: - Helpers

    /// A well-formed NotificationResponse ('A') frame the real decoder accepts: a length header, then an
    /// Int32 PID and two NUL-terminated strings (channel, payload) — unlike an empty-payload stand-in.
    private func notificationFrame(pid: Int32 = 42, channel: String = "chan", payload: String = "hi") -> [UInt8] {
        var body = withUnsafeBytes(of: pid.bigEndian) { Array($0) }
        body += Array(channel.utf8) + [0]
        body += Array(payload.utf8) + [0]
        var frame: [UInt8] = [UInt8(ascii: "A")]
        frame += withUnsafeBytes(of: Int32(body.count + 4).bigEndian) { Array($0) }   // length includes itself
        frame += body
        return frame
    }
}
