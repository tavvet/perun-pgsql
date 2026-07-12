/// A result set read lazily, one row at a time, instead of buffering the whole thing
/// in memory. Obtained from `PostgresConnection.queryStream(_:)` and consumed with
/// `for try await`:
///
/// ```swift
/// for try await row in try await connection.queryStream("SELECT id FROM big_table") {
///     process(try row.decode("id", as: Int.self))
/// }
/// ```
///
/// The stream holds the connection's wire **exclusively** for as long as it is being
/// consumed — no other query runs on that connection until the stream ends. Rows are
/// pulled on demand (the server sends them in bounded chunks), so a slow consumer
/// naturally throttles the server rather than filling memory. Stopping early (a `break`,
/// an error, or dropping the iterator) closes the server-side portal and releases the wire —
/// even if the sequence value itself is still held.
public struct PostgresRowStream: AsyncSequence, Sendable {
    public typealias Element = PostgresRow

    private let connection: PostgresConnection
    private let generation: UInt64
    private let lifetime: StreamLifetime

    init(connection: PostgresConnection, generation: UInt64) {
        self.connection = connection
        self.generation = generation
        self.lifetime = StreamLifetime(connection: connection, generation: generation)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        // Hand out the single driving iterator exactly once. The claim is synchronised because the
        // sequence is Sendable and may be copied and have makeAsyncIterator() called concurrently.
        // The driving iterator owns cleanup, so a `break` frees the wire even if the sequence is
        // retained. A second iterator is inert — no cleanup, and generation 0, which never matches
        // an active stream — so it can neither pull rows nor tear down the first iterator's stream.
        if lifetime.claimIterator() {
            return AsyncIterator(connection: connection,
                                 cleanup: StreamCleanup(connection: connection, generation: generation),
                                 generation: generation)
        }
        return AsyncIterator(connection: connection, cleanup: nil, generation: 0)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let connection: PostgresConnection
        let cleanup: StreamCleanup?     // frees the wire when the driving iterator is dropped; nil if inert
        let generation: UInt64          // 0 for an inert duplicate iterator, so next() yields nothing

        public mutating func next() async throws -> PostgresRow? {
            try await connection.nextStreamRow(generation: generation)
        }
    }
}

/// Releases a stream that the consumer abandoned before it finished. When the iterator is
/// dropped — a `break` out of the loop, the loop ending, or simply letting it go — this `deinit`
/// asks the connection to close the portal, drain the remaining rows of the current chunk, and
/// free the wire, so the connection is immediately reusable. A stream consumed to its end has
/// already cleaned up, so the connection call is a no-op.
final class StreamCleanup: @unchecked Sendable {
    private let connection: PostgresConnection
    private let generation: UInt64      // the stream this cleanup belongs to; a stale deinit is a no-op

    init(connection: PostgresConnection, generation: UInt64) {
        self.connection = connection
        self.generation = generation
    }

    deinit {
        // The shared scheduler spawns finishStream and hands the pool a handle, so release() awaits it
        // settling instead of racing the drain and handing a waiter a mid-teardown wire.
        connection.scheduleStreamTeardownFromDeinit(generation: generation)
    }
}

/// Frees a stream that was created but never iterated (the sequence value was dropped without a
/// `for await`). Once iteration begins, the iterator's `StreamCleanup` owns teardown and this
/// becomes a no-op, so a sequence *temporary* released mid-iteration can't tear down the live stream.
final class StreamLifetime: @unchecked Sendable {
    private let connection: PostgresConnection
    private let generation: UInt64
    private let lock = POSIXLock()
    private var iteratorTaken = false

    init(connection: PostgresConnection, generation: UInt64) {
        self.connection = connection
        self.generation = generation
    }

    /// Claim the single driving iterator; returns true for the first caller only. Thread-safe.
    func claimIterator() -> Bool {
        lock.withLock {
            guard !iteratorTaken else { return false }
            iteratorTaken = true
            return true
        }
    }

    deinit {
        guard !lock.withLock({ iteratorTaken }) else { return }   // an iterator owns teardown
        connection.scheduleStreamTeardownFromDeinit(generation: generation)
    }
}
