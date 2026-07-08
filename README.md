# perun-pgsql

**The PostgreSQL driver for the [Perun](#part-of-the-perun-framework) framework** —
the wire protocol (v3), authentication, type codecs, TLS and a connection pool, all
implemented from scratch in Swift. No PostgresNIO, no SwiftNIO. The only external
dependency is system OpenSSL, and only for TLS.

`perun-pgsql` is the data-access foundation for Perun's **ORM**: it owns the bytes on
the wire and hands the higher layers typed rows, prepared statements and pooling. Named
after the Slavic god of thunder, it talks to PostgreSQL over a raw socket and
async/await, and is deliberately small enough to read end to end.

```swift
import PerunPGSQL

let config = ConnectionConfiguration(
    host: "localhost", port: 5432,
    user: "perun", database: "perun", password: "secret",
    tlsMode: .verifyFull
)

let conn = try await PostgresConnection.connect(config)

// Parameterized query — values never touch the SQL string (injection-safe).
let result = try await conn.query(
    "SELECT id, name, created_at FROM users WHERE id = $1", [42])

for row in result.rows {
    let id   = try row.decode("id", as: Int.self)
    let name = try row.decode("name", as: String.self)
    let when = try row.decode("created_at", as: Date.self)
    print(id, name, when)
}

try await conn.close()
```

## Part of the Perun framework

- **Perun** — the framework (the umbrella project).
- **perun-pgsql** — *this repository*: the PostgreSQL driver — raw protocol, auth, types, TLS, pool.
- **Perun ORM** — built on top of this driver: models, relationships, query building, migrations.

This package is the lowest layer. It owns the bytes on the wire and gives the ORM typed
rows, prepared statements, a connection pool and transactions. Everything higher-level —
a query builder, row-to-model mapping, migrations — lives in the ORM and leans on the
primitives here.

> **Module name:** the Swift module is **`PerunPGSQL`** (`import PerunPGSQL`), matching the
> repository. The umbrella **Perun** framework and a future `PerunORM` build on top of it.

## Why build the driver by hand

Most Swift PostgreSQL access goes through PostgresNIO (built on SwiftNIO). An ORM *could*
sit on that — but Perun owns its stack top to bottom, so the driver is hand-built too.
Understand the protocol by building it: every layer — the big-endian framing, the SCRAM
handshake, the base-10000 numeric decoder, the TLS upgrade — is a few hundred readable
lines the ORM can rely on and reshape, not an opaque dependency.

## What's implemented

| Layer | Details |
|-------|---------|
| **Sockets** | Raw POSIX (`Darwin`/`Glibc`), blocking calls bridged to async/await off the cooperative pool |
| **Wire protocol** | v3 framing, all frontend/backend messages, simple + extended query |
| **Authentication** | `trust`, cleartext, **MD5**, **SCRAM-SHA-256** — with SHA-256/HMAC/PBKDF2/MD5/Base64 written from scratch |
| **Queries** | Simple Query, and the extended protocol: `Parse`/`Bind`/`Describe`/`Execute`/`Sync`, prepared statements, `$1` parameters (text or binary) |
| **Types** | `Int*`, `Float`/`Double`, `Bool`, `String`, `Data`/`[UInt8]` (bytea), `UUID`, `Date` (timestamp/timestamptz/date), `Decimal` (numeric), `PostgresJSON` (json/jsonb) — in **both text and binary** formats |
| **Arrays** | One-dimensional array **parameters** (`int8[]`, `text[]`, `uuid[]`, …) via `PostgresArray` — text or binary |
| **TLS** | `SSLRequest` negotiation + OpenSSL channel; modes = disable / allow plaintext fallback / encrypt without verification / verify full |
| **Pool** | `PostgresClient` — lazy, bounded, `withConnection {}`, reuse/replace, graceful shutdown |
| **Concurrency** | Per-connection FIFO async lock so overlapping queries can't interleave on the wire |
| **Extras** | `NoticeResponse` handler, **LISTEN/NOTIFY** via `AsyncStream`, query **cancellation** (`CancelRequest`) |

## Requirements

- Swift 6.0+
- OpenSSL 3 (only for TLS). On macOS: `brew install openssl@3`. On Debian/Ubuntu:
  `apt install libssl-dev`. `Package.swift` locates it automatically; override the
  path with the `OPENSSL_PREFIX` environment variable if needed.

## Usage

### Connecting

```swift
let conn = try await PostgresConnection.connect(
    ConnectionConfiguration(host: "localhost", user: "me", database: "app",
                            password: "secret", tlsMode: .verifyFull))
await conn.isSecure    // true when the channel is encrypted
```

### Prepared statements

```swift
let insert = try await conn.prepare("INSERT INTO t (a, b) VALUES ($1, $2)")
try await conn.execute(insert, [1, "one"])
try await conn.execute(insert, [2, "two"])
try await conn.execute(insert, [3, nil])          // nil → SQL NULL
```

### Typed decoding (text or binary)

```swift
// Request binary result columns; decoded values are identical to text.
let row = try await conn.query("SELECT now() AS t, 12.5::numeric AS n",
                               [], resultFormat: .binary).rows[0]
let t: Date    = try row.decode("t")
let n: Decimal = try row.decode("n")
let maybe: String? = try row.decodeIfPresent("optional")   // nil on SQL NULL
```

Parameters can likewise be sent in binary with `parameterFormat: .binary` (integer,
floating-point, bool, string, `UUID`, `Date`/timestamptz, `Data`/`[UInt8]` (bytea),
`Decimal`/numeric and `PostgresJSON` (json/jsonb) values; any other type falls back
to text).

One-dimensional arrays are sent through `PostgresArray([1, 2, 3])`, which renders the
`{…}` text form — or the binary array wire format when every element has one. Elements
are any encodable value, and `nil` is SQL NULL.

### Errors

A failed statement throws `PerunError.server(PostgresServerError)`, carrying the whole
`ErrorResponse`. Branch on the typed `sqlState` — never on the (localized) message:

```swift
do {
    try await conn.query("INSERT INTO users (email) VALUES ($1)", [email])
} catch let error as PerunError {
    switch error.serverError?.sqlState {
    case .uniqueViolation where error.serverError?.constraintName == "users_email_key":
        throw SignupError.emailTaken                       // your domain error, above the driver
    case .serializationFailure, .deadlockDetected:
        break                                              // transient (class 40…); retry is your call
    default:
        throw error
    }
}
```

`sqlStateCode` gives the raw five-character code for anything the driver doesn't name.
A server error leaves the connection healthy — it is not a wire desync — so a pooled
connection is safely reused after one.

### Connection pool

```swift
let pool = PostgresClient(configuration: config, maxConnections: 8)

let rows = try await pool.query("SELECT * FROM users").rows          // check-out/run/return

try await pool.withTransaction { tx in                               // BEGIN … COMMIT (ROLLBACK on throw)
    try await tx.query("INSERT INTO ledger (delta) VALUES ($1)", [amount])
    try await tx.query("UPDATE accounts SET balance = balance + $1", [amount])
}
await pool.shutdown()
```

### LISTEN / NOTIFY

```swift
try await conn.listen(to: "events")
Task { try await conn.waitForNotifications() }          // pump the socket
for await note in conn.notifications {
    print(note.channel, note.payload)
}
```

`notifications` uses a bounded newest-first buffer (`notificationBufferLimit`,
default `1024`) so an unconsumed notification stream cannot grow without bound.

### Cancellation

```swift
let work = Task { try await conn.query("SELECT slow_thing()") }
try await conn.cancelCurrentQuery()                     // sent on a side connection
```

## Architecture

```
        Your code
            │  async/await
   ┌────────▼─────────┐        ┌──────────────────┐
   │ PostgresClient   │  pool  │ PostgresConnection│  actor + FIFO wire lock
   │ (actor)          ├───────▶│ (actor)           │
   └──────────────────┘        └───────┬──────────┘
                                        │ framed messages
                    ┌───────────────────┼───────────────────┐
                    ▼                   ▼                   ▼
              Wire codecs          Auth (SCRAM/MD5)     Type codecs
           ByteReader/Writer      SHA256/HMAC/PBKDF2    text + binary
                    │                                       │
                    └──────────────┬────────────────────────┘
                                   ▼
                          TLSConnection (OpenSSL)   ← optional
                                   ▼
                          POSIX socket (blocking, bridged to async)
```

The core (sockets, wire, crypto, connection) is Foundation-free; only the type
layer imports Foundation for `UUID`/`Date`/`Data`/`Decimal`.

## Project layout

```
Sources/
  COpenSSL/            C-interop shim for libssl/libcrypto
  PerunPGSQL/
    Socket/            POSIX socket wrapper
    Wire/              ByteReader/Writer, frontend & backend messages
    Crypto/            SHA-256, MD5, HMAC, PBKDF2, Base64 (from scratch)
    Auth/              SCRAM-SHA-256 client
    Types/             PostgresDecodable + scalar/Foundation decoders
    TLS/               OpenSSL-backed TLSConnection
    PostgresConnection.swift   the connection actor
    PostgresClient.swift       the pool
  perun-demo/          runnable end-to-end showcase
Tests/PerunTests/      crypto vectors (RFC), SCRAM (RFC 7677), wire & type codecs, live integration
```

## Testing

```bash
swift test          # crypto/SCRAM/wire/type unit tests — no server needed
swift run perun-demo   # full showcase against a live PostgreSQL
```

The demo reads standard `PG*` environment variables
(`PGHOST`/`PGPORT`/`PGUSER`/`PGDATABASE`/`PGPASSWORD`/`PGSSLMODE`).
`PGSSLMODE` accepts `disable`, `prefer`, `require`, and `verify-full`; in Swift
code the unsafe modes are named `.allowPlaintextFallback` and
`.encryptWithoutVerification` so the risk is visible at the call site.

To bring up a throwaway server:

```bash
docker run -d --name pg -e POSTGRES_HOST_AUTH_METHOD=trust \
  -e POSTGRES_USER=perun -e POSTGRES_DB=perun -p 5432:5432 postgres:17
```

## Status & roadmap

All seven milestones are complete and verified against PostgreSQL 17. The public
surface is deliberately general: it speaks the protocol and returns rows. Query
building, models and migrations are concerns for code built *on top* of the driver,
not for the driver itself.

Not yet implemented (each on its own merits):

- **Full SASLprep** (RFC 4013) for non-ASCII passwords — currently the identity
  mapping, which is correct for ASCII.
- **Cancellation of tasks parked** in the connection lock / pool waiters.
- **Statement pipelining** — an optional throughput win over the extended protocol.

## License

[MIT](LICENSE) © 2026 Anton Rudakov.
