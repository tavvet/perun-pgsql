# Streaming large results

Consuming a big result set lazily, one row at a time, instead of buffering it all in memory.

## Streaming rows

`queryStream` returns a ``PostgresRowStream`` — an `AsyncSequence` of ``PostgresRow`` — that you
consume with `for try await`:

```swift
for try await row in try await connection.queryStream("SELECT id FROM big_table") {
    process(try row.decode("id", as: Int.self))
}
```

Rows are fetched from the server in bounded chunks (`chunkSize` rows per round trip, default 512)
and delivered on demand, so a huge result never has to fit in memory at once — only about one
chunk does. A slow consumer naturally throttles the server: it stops pulling, the socket buffer
fills, and the backend blocks on its write. Parameters (`$1`, …) and `resultFormat` work exactly
as in a normal query.

## Exclusive hold and early termination

A stream holds the connection's wire **exclusively** until it ends — like a transaction, no other
query runs on that connection while it is open. Consume it promptly, and don't open a stream
inside a ``PostgresConnection/withTransaction(_:)`` on the same connection (it would wait on a wire
the transaction already holds — use a separate connection).

Stopping early is clean: a `break`, a thrown error, or simply dropping the stream closes the
server-side portal and frees the wire, so the connection is immediately reusable.

```swift
for try await row in try await connection.queryStream("SELECT id FROM big_table") {
    if shouldStop(row) { break }   // closes the portal and frees the connection
}
```

## Cancellation

The stream is cancellation-aware: cancelling the consuming task aborts the running query (a
`CancelRequest`) and frees the wire promptly, rather than waiting for the next backend message —
see <doc:ErrorsAndRecovery>.
