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

Several autocommit queries issued concurrently on one connection are genuinely in flight together
— the driver writes each request without waiting and matches responses back in order. This trims
round-trip latency:

```swift
async let users  = connection.query("SELECT count(*) AS c FROM users")
async let orders = connection.query("SELECT count(*) AS c FROM orders")
let (u, o) = try await (users, orders)
```

Pipelining buys latency, not server-side parallelism — one backend still runs the queries
serially, and responses arrive in order, so a slow query head-of-line-blocks the ones behind it
on that connection. For real concurrency, use a <doc:ConnectionPool>.
