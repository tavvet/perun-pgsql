# Transactions

Running several statements atomically on one connection.

## withTransaction

``PostgresConnection/withTransaction(_:)`` issues `BEGIN`, runs your closure, and `COMMIT`s — or
`ROLLBACK`s if the closure throws:

```swift
try await connection.withTransaction { tx in
    try await tx.query("UPDATE accounts SET balance = balance - $1 WHERE id = $2", [amount, from])
    try await tx.query("UPDATE accounts SET balance = balance + $1 WHERE id = $2", [amount, to])
}
```

The closure receives a ``PostgresConnection/Transaction`` handle. Run statements through **it**
(`tx.query`, `tx.prepare`, `tx.execute`) so they land inside the transaction, rather than on the
connection directly.

## Exclusivity

A transaction holds the connection's wire **exclusively** from `BEGIN` to `COMMIT`/`ROLLBACK`: no
other task can pipeline a statement into it. That is what makes it atomic on the wire — and it is
why you should not open a row stream on the *same* connection inside a transaction (it would wait
on a wire the transaction already holds). Use a separate connection to stream concurrently.

## Rollback, cancellation, and retries

The transaction rolls back — never commits partial work — when the closure throws, the task is
cancelled, or a wrapping ``withTimeout(_:_:)`` fires. The `COMMIT`/`ROLLBACK` itself always
completes, so the connection is left clean and reusable. Transient conflicts (serialization
failures, deadlocks) are worth retrying the *whole* transaction — see <doc:ErrorsAndRecovery>.

## On a pool

``PostgresClient/withTransaction(_:)`` does the same on a pooled connection: it checks one out,
runs the transaction, and returns it only after `COMMIT`/`ROLLBACK` completes.

```swift
try await pool.withTransaction { tx in
    try await tx.query("INSERT INTO audit (event) VALUES ($1)", [event])
}
```
