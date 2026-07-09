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
/// the wire when it ends. Stopping early — a `break`, an error, or cancelling the task —
/// cancels the COPY server-side and releases the connection.
public struct PostgresCopyOutSequence: AsyncSequence, Sendable {
    public typealias Element = [UInt8]

    private let connection: PostgresConnection
    private let cleanup: CopyOutCleanup

    init(connection: PostgresConnection, generation: UInt64) {
        self.connection = connection
        self.cleanup = CopyOutCleanup(connection: connection, generation: generation)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(connection: connection, cleanup: cleanup)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let connection: PostgresConnection
        let cleanup: CopyOutCleanup     // retained for the iterator's lifetime; frees the wire on drop

        public mutating func next() async throws -> [UInt8]? {
            try await connection.nextCopyData()
        }
    }
}

/// Releases a `COPY … TO STDOUT` that the consumer abandoned before it finished. Dropping
/// the sequence and its iterator cancels the COPY server-side (a `CancelRequest`, since the
/// server would otherwise stream the whole relation), drains to `ReadyForQuery`, and frees
/// the wire. A copy consumed to its end has already cleaned up, so this is a no-op.
final class CopyOutCleanup: @unchecked Sendable {
    private let connection: PostgresConnection
    private let generation: UInt64      // the copy this cleanup belongs to; a stale deinit is a no-op

    init(connection: PostgresConnection, generation: UInt64) {
        self.connection = connection
        self.generation = generation
    }

    deinit {
        let connection = self.connection
        let generation = self.generation
        Task { await connection.finishCopyOut(generation: generation) }
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
