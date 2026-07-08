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

    init(connection: PostgresConnection) {
        self.connection = connection
        self.cleanup = StreamCleanup(connection: connection)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(connection: connection, cleanup: cleanup)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let connection: PostgresConnection
        let cleanup: StreamCleanup      // retained for the iterator's lifetime; frees the wire on drop

        public mutating func next() async throws -> PostgresRow? {
            try await connection.nextStreamRow()
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

    init(connection: PostgresConnection) {
        self.connection = connection
    }

    deinit {
        let connection = self.connection
        Task { await connection.finishStream() }
    }
}
