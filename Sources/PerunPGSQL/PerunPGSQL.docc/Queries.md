# Running queries

Simple and parameterised queries, prepared statements, and pipelining.

## Simple and parameterised queries

``PostgresConnection/query(_:)`` runs a statement and buffers the whole result:

```swift
let result = try await connection.query("SELECT id, email FROM users")
for row in result.rows {
    let id = try row.decode("id", as: Int.self)
    let email = try row.decode("email", as: String.self)
}
```

For values, use `$1`, `$2`, … placeholders and pass them separately — never interpolate a value
into the SQL text. Parameters travel out of band, so this is injection-safe:

```swift
let rows = try await connection.query(
    "SELECT email FROM users WHERE id = $1 AND active = $2", [userID, true]
).rows
```

The result is a ``QueryResult``: `rows` (each a ``PostgresRow``) plus `commandTag` (e.g.
`"INSERT 0 1"`). A statement that returns nothing, like an `UPDATE`, simply yields empty `rows`.

Results come back in **text** format by default; pass `resultFormat: .binary` to request binary
instead. Decoded values are identical either way — the types guide covers the difference.

## Prepared statements

Parse a statement once and run it repeatedly with ``PostgresConnection/prepare(_:)`` and
`execute`:

```swift
let statement = try await connection.prepare("SELECT email FROM users WHERE id = $1")
for id in ids {
    let email = try await connection.execute(statement, [id])
        .rows.first?.decode("email", as: String.self)
}
```

A ``PreparedStatement`` is **scoped to the connection that created it** — running it on a
different connection (say, another one from a pool) throws
``PerunError/preparedStatementConnectionMismatch``. Prepare and execute on the same connection:
inside one ``PostgresClient/withConnection(_:)`` or a transaction.

## Pipelining

Pipelining sends several statements before reading any reply, so `N` statements cost one round
trip instead of `N` — a large win for bulk writes.

Run one prepared statement over many parameter sets with `pipeline`, which is **atomic** (one
implicit transaction: every set commits, or the batch rolls back and throws):

```swift
let insert = try await connection.prepare("INSERT INTO t (a, b) VALUES ($1, $2)")
try await connection.pipeline(insert, [[1, "one"], [2, "two"], [3, "three"]])
```

`pipelineIndependently` instead gives each set its own autocommit unit — one failing neither rolls
back nor skips the others — and returns a per-set `Result`:

```swift
for outcome in try await connection.pipelineIndependently(insert, sets) {
    if case .failure(let error) = outcome { /* this set failed; the others still ran */ }
}
```

A batch can also mix different statements — pass an array of ``PostgresQuery``:

```swift
try await connection.pipeline([
    PostgresQuery("INSERT INTO log (msg) VALUES ($1)", ["started"]),
    PostgresQuery("UPDATE counters SET n = n + 1 WHERE k = $1", ["runs"]),
])
```

Because every request is sent before any reply is read, a command can't depend on an earlier
one's result, and the batch should have small per-command results — pipelining is for bulk
`INSERT`/`UPDATE`, not for fetching large result sets. (Ordinary concurrent autocommit queries on
one connection pipeline too; for real parallelism, use a <doc:ConnectionPool>.)
