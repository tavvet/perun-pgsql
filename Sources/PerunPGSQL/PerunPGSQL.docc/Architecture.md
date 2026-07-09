# Architecture

How the driver is put together: the layers, the concurrency model, and what it deliberately leaves
to a higher layer.

## Layers

```
your code
   │
   ▼
PostgresClient            — a pool of connections (this is where concurrency comes from)
   │
   ▼
PostgresConnection        — an actor: one connection, its protocol state, and a wire lock
   │
   ▼
Frontend / BackendMessage — v3 wire-protocol codecs over ByteReader / ByteWriter
   │
   ▼
TLSConnection?  →  POSIX socket    — plaintext, or OpenSSL-encrypted, bytes
   │
   ▼
PostgreSQL server
```

Everything above the socket is written from scratch in Swift — the wire framing, the message
codecs, even the authentication crypto (SHA-256, HMAC, PBKDF2, MD5, Base64). The only external
dependency is OpenSSL, and only for the TLS transport.

## Concurrency

A ``PostgresConnection`` is an `actor`, so its socket buffers and protocol state are isolated.
Because actors are re-entrant across `await`, that alone would still let two overlapping calls
interleave their protocol messages, so wire access also goes through a readers-writer lock:

- **Shared** — autocommit `query` / `execute` and pipelined batches. Several can be in flight on
  one connection at once; a background reader hands their responses back in FIFO order (the v3
  protocol has no request IDs). This trims round-trip latency.
- **Exclusive** — transactions, row streams, `COPY`, and `waitForNotifications`. These span
  several round trips, so they take the wire exclusively; new shared queries wait rather than
  interleave into them.

The background reader runs on its own dispatch queue and exits once its queue drains, so a
connection dropped without an explicit `close()` can still be reclaimed. Real parallelism comes
from running many connections — that is what ``PostgresClient`` is for. See <doc:ConnectionPool>
and <doc:ErrorsAndRecovery> for how the pool reuses or discards a connection after each request.

## Protocol coverage

- **Startup & authentication** — TLS negotiation (`SSLRequest`), then SCRAM-SHA-256 (mutually
  authenticating), MD5, or cleartext-password. The driver pins a few session GUCs so its text
  decoders read a known format.
- **Queries** — the Simple Query protocol for text autocommit statements, and the Extended
  protocol (`Parse` / `Bind` / `Describe` / `Execute` / `Sync`) for parameters, prepared
  statements, and binary results.
- **Bulk data** — the `COPY` sub-protocol, in both directions.
- **Out of band** — `LISTEN` / `NOTIFY` delivery and query cancellation (a `CancelRequest` sent on
  a side connection).

## Lifecycles

- **Connection** — `connect` opens the socket, negotiates TLS, authenticates, pins the session
  GUCs, and reads through to the first `ReadyForQuery`. `close()` — or, as a safety net,
  deallocation — tears the socket down.
- **Query** — every request runs to a `ReadyForQuery` before its connection is released, so a
  connection is always handed back in a known-good state (or discarded if the wire desynchronised —
  see <doc:ErrorsAndRecovery>).
- **Pool** — connections open lazily up to a bound, are validated on borrow, optionally recycled by
  age, and closed on `shutdown()`.

## What it leaves out

PerunPGSQL is a **data-access driver**. It moves rows and values; it does not build SQL, map tables
onto model types, run migrations, or turn a composite type into a `struct`. Those belong to a
higher layer built on top of it — the driver's job is to be a correct, predictable foundation for
one.
