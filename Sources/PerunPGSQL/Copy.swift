// Public surface for the PostgreSQL COPY sub-protocol. The driver moves raw `CopyData`
// payloads in either direction; the bytes are in the COPY statement's format (text, CSV,
// or binary) and are opaque here — formatting and parsing rows belongs to a higher layer.

/// The payload of a `COPY … TO STDOUT`, streamed as raw `CopyData` chunks. Obtained from
/// `PostgresConnection.copyOut(_:)` and consumed with `for try await`:
///
/// ```swift
/// for try await chunk in try await connection.copyOut("COPY events TO STDOUT") {
///     try file.write(contentsOf: chunk)
/// }
/// ```
///
/// Each element is one `CopyData` message's bytes — for text/CSV that is typically one row,
/// but the protocol may split or combine rows, so treat the stream as a byte stream, not a
/// row sequence. Like `queryStream`, it holds the connection's wire **exclusively** until it
/// is consumed, delivers chunks on demand (a slow consumer throttles the server), and frees
/// the wire when it ends. Stopping early — even while the sequence value is held — is handled two
/// ways, neither sending a `CancelRequest`: a `break` or an error drains the remainder to resync and
/// keep the connection (bounded, so a large remainder closes it instead), while cancelling the task
/// tears the connection down at once.
public struct PostgresCopyOutSequence: AsyncSequence, Sendable {
    public typealias Element = [UInt8]

    private let connection: PostgresConnection
    private let generation: UInt64
    private let lifetime: CopyOutLifetime

    init(connection: PostgresConnection, generation: UInt64) {
        self.connection = connection
        self.generation = generation
        self.lifetime = CopyOutLifetime(connection: connection, generation: generation)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        // Hand out the single driving iterator exactly once, synchronised (the sequence is Sendable;
        // see PostgresRowStream). It owns cleanup, so a `break` frees the wire even when the sequence
        // is retained; a second iterator is inert (no cleanup, generation 0).
        if lifetime.claimIterator() {
            return AsyncIterator(connection: connection,
                                 cleanup: CopyOutCleanup(connection: connection, generation: generation),
                                 generation: generation)
        }
        return AsyncIterator(connection: connection, cleanup: nil, generation: 0)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let connection: PostgresConnection
        let cleanup: CopyOutCleanup?    // frees the wire when the driving iterator is dropped; nil if inert
        let generation: UInt64          // 0 for an inert duplicate iterator, so next() yields nothing

        public mutating func next() async throws -> [UInt8]? {
            try await connection.nextCopyData(generation: generation)
        }
    }
}

/// Releases a `COPY … TO STDOUT` that the consumer abandoned before it finished. If the consuming
/// task was cancelled — including a `CancellationError` thrown from the `for await` *body*, which
/// unwinds through here rather than through `nextCopyData` — the connection is torn down at once.
/// Otherwise (a plain `break`) the remainder is drained to `ReadyForQuery`, bounded by
/// `copyResyncTimeout`: the connection is kept when the remainder is cheap and closed when it isn't.
/// No `CancelRequest` either way. A copy consumed to its end has already cleaned up, so this is a
/// no-op.
final class CopyOutCleanup: @unchecked Sendable {
    private let connection: PostgresConnection
    private let generation: UInt64      // the copy this cleanup belongs to; a stale deinit is a no-op

    init(connection: PostgresConnection, generation: UInt64) {
        self.connection = connection
        self.generation = generation
    }

    deinit {
        // Routing (cancel → discard, break → drain) and the record-for-the-pool live on the shared
        // scheduler; Task.isCancelled must be read there, synchronously on this unwinding task.
        connection.scheduleCopyOutTeardownFromDeinit(generation: generation)
    }
}

/// Frees a copy that was created but never iterated. Once iteration begins the iterator's
/// `CopyOutCleanup` owns teardown, so a sequence temporary released mid-iteration is a no-op here.
final class CopyOutLifetime: @unchecked Sendable {
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
        connection.scheduleCopyOutTeardownFromDeinit(generation: generation)
    }
}

/// Writes `CopyData` to a `COPY … FROM STDIN` in progress. Passed to the `copyIn` closure;
/// each `write` sends one `CopyData` message with the caller's bytes in the COPY statement's
/// format (text/CSV/binary). Valid only inside that closure — a write afterwards throws.
public struct PostgresCopyInWriter: Sendable {
    let connection: PostgresConnection
    let generation: UInt64          // ties this writer to one copyIn; a later copy rejects it

    /// Send one chunk of COPY payload. Batch rows into reasonably sized chunks; an empty
    /// chunk is a no-op.
    public func write(_ bytes: [UInt8]) async throws {
        try await connection.sendCopyData(bytes, generation: generation)
    }

    /// Send `text`'s UTF-8 bytes as COPY payload — convenient for text/CSV COPY.
    public func write(_ text: String) async throws {
        try await connection.sendCopyData(Array(text.utf8), generation: generation)
    }
}
