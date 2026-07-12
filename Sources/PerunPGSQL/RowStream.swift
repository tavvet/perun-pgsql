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
    private let lifetime: AbandonedSequenceLifetime

    init(connection: PostgresConnection, generation: UInt64) {
        self.connection = connection
        self.generation = generation
        self.lifetime = AbandonedSequenceLifetime(connection: connection, generation: generation, mode: .stream)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        // Hand out the single driving iterator exactly once. The claim is synchronised because the
        // sequence is Sendable and may be copied and have makeAsyncIterator() called concurrently.
        // The driving iterator owns cleanup, so a `break` frees the wire even if the sequence is
        // retained. A second iterator is inert — no cleanup, and generation 0, which never matches
        // an active stream — so it can neither pull rows nor tear down the first iterator's stream.
        if lifetime.claimIterator() {
            return AsyncIterator(connection: connection,
                                 cleanup: AbandonedSequenceCleanup(connection: connection, generation: generation, mode: .stream),
                                 generation: generation)
        }
        return AsyncIterator(connection: connection, cleanup: nil, generation: 0)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let connection: PostgresConnection
        let cleanup: AbandonedSequenceCleanup?   // frees the wire when the driving iterator is dropped; nil if inert
        let generation: UInt64          // 0 for an inert duplicate iterator, so next() yields nothing

        public mutating func next() async throws -> PostgresRow? {
            try await connection.nextStreamRow(generation: generation)
        }
    }
}

