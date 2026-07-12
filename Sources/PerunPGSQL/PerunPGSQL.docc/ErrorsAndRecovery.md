# Errors and recovery

How PerunPGSQL reports failures, which of them leave a connection reusable, and how cancellation
and timeouts behave.

## Overview

Every failure the driver surfaces is one of two kinds:

- ``PerunError`` — the driver's own error type (an `enum`). It covers everything from a closed
  connection to a decode failure, and it *wraps* server errors in its `server` case.
- ``PostgresServerError`` — a structured error the **server** sent (a protocol `ErrorResponse`),
  carrying a typed ``SQLState``. You reach it through `PerunError.server`, or more conveniently
  through ``PerunError/serverError``.

So a single `catch` on `PerunError` sees both, and you branch from there:

```swift
do {
    _ = try await connection.query("INSERT INTO accounts VALUES ($1)", [email])
} catch let error as PerunError where error.serverError?.sqlState == .uniqueViolation {
    // the address is already taken — a domain case, not a driver failure
}
```

## Server errors and SQLState

A ``PostgresServerError`` exposes the fields PostgreSQL sent. The one to branch on is
``PostgresServerError/sqlState`` — the SQL-standard five-character condition code, as a typed
``SQLState``. Unlike the human-readable ``PostgresServerError/message`` (localised and
version-dependent), the SQLState is stable, so it is what your code should switch on.

```swift
switch error.serverError?.sqlState {
case .uniqueViolation:      // 23505
case .foreignKeyViolation:  // 23503
case .serializationFailure: // 40001 — transient, see "Retrying" below
default:                    break
}
```

Common conveniences:

- ``SQLState/isIntegrityConstraintViolation`` — the whole `23xxx` class (unique, foreign-key,
  not-null, check, exclusion).
- ``SQLState/isTransactionRollback`` — the `40xxx` class (serialization failure, deadlock).
- ``PostgresServerError/constraintName`` — which constraint failed, turning "some unique error"
  into "this exact one".
- ``PostgresServerError/sqlStateCode`` — the raw string, for a condition the driver does not name.

## The reusability contract

This is the part that matters for pooling. After an error, a connection is either **in sync** —
its wire sits at a clean `ReadyForQuery`, so the next query just works — or **desynchronised** —
stopped mid-message in an unknown state, where the next read would misframe the stream. PerunPGSQL
classifies every error this way:

| Reusable (wire in sync) | Discard (wire may be desynchronised) |
| --- | --- |
| `server` — a SQL error, drained to `ReadyForQuery` before it was reported | `connectionClosed` — EOF mid-message |
| `decodingFailed`, `unexpectedNull`, `columnNotFound` — the row arrived; decoding is client-side | `ioError` — a raw socket read/write failure (e.g. the peer reset the connection) |
| `timedOut` — the query was cancelled and drained (see Timeouts) | `protocolViolation` — the server sent something unexpected |
| `copyMismatch` — a non-COPY statement, or `copyOut` on a `COPY … FROM STDIN`; its handshake is drained first (but see the note below — many COPY mismatches instead close) | `tlsIO`, `tlsHandshakeFailed`, `tlsNotAvailable` — TLS failures |
| an error thrown by your own `withConnection` / `withTransaction` closure | `authenticationFailed`, `unsupportedAuthentication` |

With ``PostgresClient`` you never act on this yourself. On release the pool checks the
classification and either returns the connection to the pool or closes it and — if a caller is
waiting — opens a replacement. A connection handed back still inside a transaction is discarded too.

With a bare ``PostgresConnection`` the same rule applies, but you act on it: after a reusable
error keep using the connection; after a desynchronising one, `close()` it and open a fresh one.

> Note: raw socket faults on a plaintext connection surface as `ioError` (mapped from the socket
> layer at the I/O boundary) specifically so they are classified as desynchronising — a broken
> connection is never handed back out of the pool.

> Note: `copyMismatch` is often **not** reusable. Any COPY run through `query`/`execute`, a
> pipeline, or `queryStream`, and a `copyIn` on a `COPY … TO STDOUT`, **close** the connection —
> a COPY-out can't be stopped in band, a COPY-in over the extended protocol can't be
> resynchronised with `CopyFail`, and the stream may be huge or unbounded, so draining it to keep
> the connection isn't worth it. The pool discards a connection closed this way. The reusable
> cases are a non-COPY statement and `copyOut` on a `COPY … FROM STDIN`, which are aborted in band
> with `CopyFail` and drained.

## Cancellation

PerunPGSQL is cancellation-aware. Cancelling the task running a query — or a `for await` over a
``PostgresRowStream`` — sends the server a `CancelRequest`, so a statement blocked in the backend (a
long `pg_sleep`, a lock wait) unblocks promptly instead of running to completion, and the response is
drained to `ReadyForQuery` so the connection is left in sync and stays reusable.

Cancellation is **best-effort**, and this matters for correctness:

> Important: `CancellationError` means "we asked the server to cancel", not "the statement did not
> run". The request races the query — it can arrive after the statement already committed, or
> before it even reached the server. Treat a cancelled write as *unknown*, not *rolled back*.

A ``PostgresCopyOutSequence`` is the exception: a COPY-out can't be stopped in band, so cancelling
one (including via a wrapping ``withTimeout(_:_:)``) **tears the connection down and discards it**
rather than draining and keeping it — the pool opens a replacement when a caller is waiting (an idle
pool just shrinks until the next acquire). Breaking out of a copyOut *without* cancelling instead
drains the remainder to keep the connection (closing it if the remainder is large); neither path
sends a `CancelRequest`, so the server-side COPY keeps running until its next write to the closed
socket fails.

## Timeouts

``withTimeout(_:_:)`` runs an operation under a deadline, throwing `PerunError.timedOut` if it
does not finish in time. It is built on cancellation, so it composes over anything — a single
query, a pooled ``PostgresClient/query(_:_:parameterFormat:resultFormat:)``, or a whole
``PostgresConnection/withTransaction(_:)``:

```swift
let report = try await withTimeout(.seconds(5)) {
    try await connection.query("SELECT * FROM slow_report").rows
}
```

On a timeout the underlying query is cancelled (a `CancelRequest`) and its response drained to
`ReadyForQuery` **before** `withTimeout` returns — so the connection is left in sync and stays
reusable (`timedOut` is not a desynchronising error). The best-effort caveat from cancellation
applies unchanged: a timed-out statement may still have run. (Timing out a `copyOut` is the
exception noted under Cancellation — it tears the connection down rather than keeping it.)

## Transactions and failure

``PostgresConnection/withTransaction(_:)`` issues `BEGIN`, runs your closure, and finishes with
`COMMIT` — or `ROLLBACK` if the closure throws, is cancelled, or times out. The control statements
always complete, so:

- an error inside the transaction rolls back and rethrows the cause;
- a cancel or a timeout observed *before* `COMMIT` is sent rolls back rather than committing partial
  work; but once `COMMIT` is on the wire it runs uncancellable, so a cancel racing it may still
  commit while the caller sees `CancellationError`/`timedOut` — treat that outcome as unknown, per
  the best-effort caveat above;
- a connection returned to the pool still inside a transaction (or a failed one) is discarded,
  never reused mid-transaction.

## Retrying transient failures

Two conditions are transient — the server rolled your transaction back and a retry may succeed:
``SQLState/serializationFailure`` (`40001`) and ``SQLState/deadlockDetected`` (`40P01`).
``SQLState/isTransactionRollback`` covers both. Whether and how often to retry is your policy:

```swift
func withRetry<T>(maxAttempts: Int = 3, _ body: () async throws -> T) async throws -> T {
    var attempt = 0
    while true {
        attempt += 1
        do {
            return try await body()
        } catch let error as PerunError
            where attempt < maxAttempts && (error.serverError?.sqlState?.isTransactionRollback ?? false) {
            continue   // serialization failure or deadlock — retry the whole transaction
        }
    }
}

let balance = try await withRetry {
    try await pool.withTransaction { tx in
        // …transfer funds…
    }
}
```

Retry the *whole* transaction, not a single statement: the server has already rolled the
transaction back, so there is nothing to resume.
