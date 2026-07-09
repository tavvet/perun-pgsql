# Connection pool

Sharing a bounded set of connections for concurrent work.

## PostgresClient

``PostgresClient`` opens up to `maxConnections` connections lazily and hands them out one request
at a time. It is the right tool for anything concurrent — a server handling many requests, or a
parallel job:

```swift
let pool = PostgresClient(configuration: config, maxConnections: 8)
defer { Task { await pool.shutdown() } }

let count = try await pool.query("SELECT count(*)::int AS c FROM users")
    .rows[0].decode("c", as: Int.self)
```

Fan out freely — the pool serialises access and opens at most `maxConnections` connections,
queueing further callers until one frees up:

```swift
try await withThrowingTaskGroup(of: Int.self) { group in
    for id in ids {
        group.addTask { try await pool.query("SELECT n FROM t WHERE id = $1", [id]).rows[0].decode("n", as: Int.self) }
    }
    for try await n in group { total += n }
}
```

## Checking out a connection

Use ``PostgresClient/withConnection(_:)`` when several statements must run on the **same**
connection — a prepared statement and its executions, or `LISTEN` and then a wait:

```swift
try await pool.withConnection { connection in
    let statement = try await connection.prepare("SELECT n FROM t WHERE id = $1")
    for id in ids { _ = try await connection.execute(statement, [id]) }
}
```

``PostgresClient/withTransaction(_:)`` is the transaction shortcut — see <doc:Transactions>.

## Reuse, recycling, and shutdown

After each request the pool returns the connection to its idle set, unless the request may have
desynchronised the wire — then it is discarded and replaced (<doc:ErrorsAndRecovery> lists which
errors do that). Before reusing an idle connection the pool runs a cheap liveness probe, so one
the server dropped while it sat idle is never handed out dead.

You can bound connection age with `maxConnectionLifetime` and `maxIdleTime` (both default to no
limit); a background reaper recycles connections past their limit and the lazy pool reopens on
demand. Always call ``PostgresClient/shutdown()`` when finished — it closes every pooled
connection and fails anyone still waiting.
