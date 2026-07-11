# perun-pgsql

[![CI](https://github.com/tavvet/perun-pgsql/actions/workflows/ci.yml/badge.svg)](https://github.com/tavvet/perun-pgsql/actions/workflows/ci.yml)

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
| **Queries** | Simple Query, and the extended protocol: `Parse`/`Bind`/`Describe`/`Execute`/`Sync`, prepared statements, `$1` parameters (text or binary), pipelined bulk execution (atomic / independent), row **streaming** for large results, and **COPY** in/out for bulk load and dump |
| **Types** | `Int*`, `Float`/`Double`, `Bool`, `String`, `Data`/`[UInt8]` (bytea), `UUID`, `Date` (timestamp/timestamptz/date), `Decimal` (numeric), `PostgresInterval` (interval), `PostgresTime`/`PostgresTimeTz` (time/timetz), `PostgresInet` (inet/cidr), `PostgresJSON` (json/jsonb) — in **both text and binary** formats |
| **Arrays** | Multi-dimensional array **parameters** (`int8[]`, `text[]`, `uuid[]`, …) via `PostgresArray`, and **decoding** columns into `[T]`, `[[T]]`, `[[[T]]]` and deeper via `decodeArray` — text or binary |
| **TLS** | `SSLRequest` negotiation + OpenSSL channel; modes = disable / allow plaintext fallback / encrypt without verification / verify full |
| **Pool** | `PostgresClient` — lazy, bounded, `withConnection {}`, reuse/replace, graceful shutdown |
| **Concurrency** | Readers-writer wire access (cancellation-aware): concurrent autocommit queries, `prepare`s, `execute`s and pipelined batches **pipeline** on one connection via a background reader; transactions take it exclusively. Cancelling a parked task fails it cleanly |
| **Extras** | `NoticeResponse` handler, **LISTEN/NOTIFY** via `AsyncStream`, query **cancellation** (`CancelRequest`), `withTimeout` **deadlines**, connection-pool validate-on-borrow |

## Requirements

- Swift 6.0+
- OpenSSL 3 (only for TLS), located via `pkg-config`. On macOS:
  `brew install openssl@3 pkg-config`, then — `openssl@3` is keg-only —
  `export PKG_CONFIG_PATH="$(brew --prefix openssl@3)/lib/pkgconfig"`. On Debian/Ubuntu:
  `apt install libssl-dev pkg-config` (no further configuration needed).

## Documentation

The full guides are DocC articles. Build them (into a `.doccarchive` you can open in Xcode)
with:

```bash
./Scripts/build-docs.sh
```

- **Getting started** — install, connect, run your first query.
- **Connecting** — configuration, the TLS modes, and authentication.
- **Running queries** — parameters, prepared statements, and pipelining.
- **Transactions** and **Connection pool** — atomic work and concurrency.
- **Streaming**, **COPY**, and **LISTEN / NOTIFY** — large results, bulk load/dump, notifications.
- **Decoding and encoding** — the type system, arrays, and custom codecs.
- **Errors and recovery** — the error model, the reusability contract, cancellation, timeouts.
- **Architecture** — how the driver is put together.

Runnable, compile-checked examples live in [`Examples/`](Examples): `swift run Examples <scenario>`
(e.g. `basic-query`, `transactions`, `streaming`, `copy`, `notifications`, `custom-type`).

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
  COpenSSL/            C-interop shim for libssl/libcrypto (located via pkg-config)
  PerunPGSQL/
    Socket/            POSIX socket wrapper
    Wire/              ByteReader/Writer, frontend & backend messages
    Crypto/            SHA-256, MD5, HMAC, PBKDF2, Base64 (from scratch)
    Auth/              SCRAM-SHA-256 client
    Types/             PostgresDecodable + scalar/Foundation decoders
    TLS/               OpenSSL-backed TLSConnection
    PostgresConnection.swift   the connection actor
    PostgresClient.swift       the pool
    PerunPGSQL.docc/           the documentation guides
  perun-demo/          a small runnable program
Examples/              runnable, compile-checked examples (swift run Examples <scenario>)
Tests/PerunTests/      crypto vectors (RFC), SCRAM (RFC 7677), wire & type codecs, live integration
Scripts/build-docs.sh  builds the DocC documentation
```

## Testing

With OpenSSL on the `pkg-config` path (see [Requirements](#requirements)):

```bash
swift test                      # unit tests (crypto vectors, SCRAM, wire, type codecs) — no server
swift run Examples basic-query  # a runnable example against a live PostgreSQL
```

Integration tests run against a live server when `PERUN_PGSQL_INTEGRATION=1`; they and the
examples read the standard `PG*` variables (`PGHOST` / `PGPORT` / `PGUSER` / `PGDATABASE` /
`PGPASSWORD` / `PGSSLMODE`). To bring up a throwaway server:

```bash
docker run -d --name pg -e POSTGRES_HOST_AUTH_METHOD=trust \
  -e POSTGRES_USER=perun -e POSTGRES_DB=perun -p 5432:5432 postgres:17
```

## Status & roadmap

All seven milestones are complete and verified against PostgreSQL 17, including full
SASLprep (RFC 4013) password preparation. Production hardening is in place too: query
`withTimeout` deadlines, pooled-connection validate-on-borrow and age-based recycling
(`maxConnectionLifetime` / `maxIdleTime`), and pinned session GUCs for reliable text
decoding. The public surface is deliberately general: it speaks the protocol and returns
rows. Query building, models and migrations are concerns for code built *on top* of the
driver, not for the driver itself.

The remaining PostgreSQL types — **`range`** and **`composite`** — stay readable as `String`
(or raw bytes); typed decoders for them are deliberately out of scope: they're niche, and
mapping a composite row to a struct is the ORM's job, not the driver's. Enums already decode
as `String` (their label).

## License

[MIT](LICENSE) © 2026 Anton Rudakov.
