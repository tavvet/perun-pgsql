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
/// an error, or dropping the stream) closes the server-side portal and releases the wire.
public struct PostgresRowStream: AsyncSequence, Sendable {
    public typealias Element = PostgresRow

    private let connection: PostgresConnection
    private let cleanup: StreamCleanup
    private let generation: UInt64

    init(connection: PostgresConnection, generation: UInt64) {
        self.connection = connection
        self.generation = generation
        self.cleanup = StreamCleanup(connection: connection, generation: generation)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(connection: connection, cleanup: cleanup, generation: generation)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let connection: PostgresConnection
        let cleanup: StreamCleanup      // retained for the iterator's lifetime; frees the wire on drop
        let generation: UInt64          // the stream this iterator pulls from; a stale next() reads nothing

        public mutating func next() async throws -> PostgresRow? {
            try await connection.nextStreamRow(generation: generation)
        }
    }
}

/// Releases a stream that the consumer abandoned before it finished. When the last
/// reference to the stream and its iterator is dropped — a `break` out of the loop, or
/// simply letting them go — this `deinit` asks the connection to close the portal, drain
/// the remaining rows of the current chunk, and free the wire, so the connection is
/// immediately reusable. A stream consumed to its end has already cleaned up, so the
/// connection call is a no-op.
final class StreamCleanup: @unchecked Sendable {
    private let connection: PostgresConnection
    private let generation: UInt64      // the stream this cleanup belongs to; a stale deinit is a no-op

    init(connection: PostgresConnection, generation: UInt64) {
        self.connection = connection
        self.generation = generation
    }

    deinit {
        let connection = self.connection
        let generation = self.generation
        Task { await connection.finishStream(generation: generation) }
    }
}
