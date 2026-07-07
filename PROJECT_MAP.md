# perun-pgsql: техническая карта проекта

Дата среза: 2026-07-07.

Этот документ не заменяет `README.md`. Его задача - быстро объяснить устройство
кода, основные потоки выполнения, границы модулей и места, которые важны для
дальнейшего review/refactoring.

## Назначение

`perun-pgsql` - низкоуровневый PostgreSQL driver для Swift/Perun. Он реализует:

- PostgreSQL frontend/backend protocol v3 поверх raw POSIX socket.
- Startup/auth/query loops без SwiftNIO/PostgresNIO.
- TLS upgrade через OpenSSL.
- Authentication: trust, cleartext password, MD5, SCRAM-SHA-256.
- Simple Query и Extended Query protocol.
- Prepared statements.
- Typed row/cell decoding в text и binary result formats.
- Lazy bounded connection pool.
- LISTEN/NOTIFY, NoticeResponse handler и CancelRequest.

Публичная библиотека: `PerunPGSQL`.
Демо-таргет: `perun-demo`.

## Package Layout

```text
Package.swift
Sources/
  COpenSSL/
    module.modulemap
    shim.h
  PerunPGSQL/
    PostgresConnection.swift
    PostgresClient.swift
    Result.swift
    Statement.swift
    Encoding.swift
    Errors.swift
    Notification.swift
    Concurrency.swift
    Socket/
      POSIXSocket.swift
    TLS/
      TLSConnection.swift
    Wire/
      ByteBuffer.swift
      FrontendMessage.swift
      BackendMessage.swift
    Auth/
      SCRAM.swift
    Crypto/
      Base64.swift
      Hex.swift
      MD5.swift
      SHA256.swift
      HMAC.swift
      PBKDF2.swift
    Types/
      PostgresDecodable.swift
      ScalarTypes.swift
      FoundationTypes.swift
  perun-demo/
    Demo.swift
Tests/
  PerunTests/
    CryptoTests.swift
    SCRAMTests.swift
    WireTests.swift
    FramingTests.swift
    TypeTests.swift
```

## Target Map

### `COpenSSL`

System library target exposing OpenSSL symbols to Swift.

- `shim.h` wraps OpenSSL macros/functions that are awkward from Swift.
- `module.modulemap` defines the Clang module.
- `Package.swift` adds OpenSSL include/lib paths through unsafe flags.

OpenSSL prefix detection order:

1. `OPENSSL_PREFIX`
2. Apple Silicon Homebrew paths.
3. Intel Homebrew paths.
4. `/usr` for Linux-style installs.

### `PerunPGSQL`

Main library target.

Core design:

- `PostgresConnection` is an actor and owns one backend connection.
- Blocking socket/TLS calls are moved to a serial `DispatchQueue`.
- Actor reentrancy is controlled with an internal FIFO wire lock.
- Wire bytes are encoded/decoded by local `ByteWriter`/`ByteReader`.
- The driver returns `QueryResult`, `PostgresRow`, and `PostgresCell`.

### `perun-demo`

End-to-end executable. It demonstrates:

- connection and TLS mode parsing from `PG*` env vars;
- simple query;
- parameterized query;
- prepared statements;
- typed decoding in text and binary formats;
- single-connection concurrency serialization;
- pool concurrency;
- notices;
- LISTEN/NOTIFY;
- query cancellation.

It requires a live PostgreSQL server.

## Core Runtime Model

```text
Application code
    |
    v
PostgresClient actor
    |
    | acquire/release
    v
PostgresConnection actor
    |
    | FIFO wire lock around each protocol exchange
    v
FrontendMessage / BackendMessage
    |
    | ByteWriter / ByteReader
    v
TLSConnection? -> SystemSocket
    |
    v
PostgreSQL backend
```

`PostgresConnection` is the central object. It owns:

- the file descriptor;
- optional `TLSConnection`;
- read buffer and read cursor;
- backend runtime parameters;
- backend PID/secret key for cancellation;
- SCRAM in-flight state;
- prepared statement counter;
- notification stream continuation;
- FIFO lock waiters.

## Connection Lifecycle

### Open

Entry point:

- `PostgresConnection.connect(_:)`

Flow:

1. Create a dedicated serial `DispatchQueue`.
2. Open a TCP socket through `SystemSocket.makeConnected`.
3. If TLS mode is not `.disable`, send `SSLRequest`.
4. If server replies `S`, wrap the fd in `TLSConnection`.
5. Send startup packet.
6. Read backend messages until `ReadyForQuery`.
7. Return the initialized actor.

Failure path:

- Any error during TLS/startup calls `forceClose()`.
- `forceClose()` shuts down the fd, finishes the notification stream, then queues TLS/socket teardown.

### TLS Modes

Defined in `TLSMode`:

- `.disable`: never use TLS.
- `.prefer`: request TLS, fall back to plaintext if server says no.
- `.require`: require TLS encryption, but do not verify certificate/hostname.
- `.verifyFull`: require TLS and verify chain/hostname.

`TLSConnection.connect(fd:hostname:verifyFull:)` configures OpenSSL. SNI is set
for all TLS connections; certificate verification and hostname verification are
only enabled for `.verifyFull`.

### Authentication

Authentication is handled in `handleAuthentication(_:configuration:)`.

Supported backend requests:

- `AuthenticationOk`
- `AuthenticationCleartextPassword`
- `AuthenticationMD5Password`
- `AuthenticationSASL`
- `AuthenticationSASLContinue`
- `AuthenticationSASLFinal`

SCRAM implementation lives in `Auth/SCRAM.swift` and uses local crypto
primitives:

- SHA-256
- HMAC-SHA-256
- PBKDF2
- Base64

Important review note: the SCRAM client verifies the server final signature when
`SASLFinal` is received, but the connection authentication state should also
ensure `AuthenticationOk` cannot finish a SCRAM exchange before a valid
`SASLFinal`.

## Query Execution

All public query APIs on `PostgresConnection` acquire the internal wire lock:

- `query(_ sql: String)`
- `query(_:_:resultFormat:)`
- `prepare(_:)`
- `execute(_:_:resultFormat:)`
- `closePrepared(_:)`
- `waitForNotifications()`

The actor alone is not enough because actors are reentrant across `await`.
Without the explicit lock, two tasks could interleave protocol messages on one
socket.

### Simple Query

Entry point:

- `runSimpleQuery(_:)`

Flow:

1. Encode `Q` message through `FrontendMessage.query`.
2. Send bytes.
3. Call `collectResults()`.
4. Read until `ReadyForQuery`.
5. Return the last row-producing result set and command tag.

The simple query string may contain multiple SQL statements.

### Parameterized Query

Entry point:

- `runParameterizedQuery(_:_:resultFormat:)`

If there are no parameters and text results were requested, it falls back to
Simple Query for a cheaper round trip.

Otherwise it sends one extended-protocol request batch:

```text
Parse unnamed statement
Bind unnamed portal
Describe portal
Execute portal
Sync
```

Parameters are encoded as text. Result columns can be requested as text or
binary.

### Prepared Statements

Entry points:

- `runPrepare(_:)`
- `runExecute(_:_:resultFormat:)`
- `runClosePrepared(_:)`

Prepare sends:

```text
Parse named statement
Describe statement
Sync
```

The returned `PreparedStatement` contains:

- server-side statement name;
- parameter type OIDs;
- result columns.

Execution sends:

```text
Bind unnamed portal to named statement
Execute portal
Sync
```

Important review note: prepared statement names are currently generated from a
per-connection counter (`perun_stmt_N`). A handle from one connection can name a
different statement on another pooled connection unless ownership or globally
unique names are added.

## Result Model

Main types:

- `ColumnMetadata`
- `PostgresCell`
- `PostgresRow`
- `QueryResult`

`QueryResult` stores:

- column metadata;
- rows;
- command tag.

`PostgresRow` stores values and columns. It supports:

- index access: `row[0]`
- optional name access: `row["id"]`

Important review note: by-name access returns optional. User code like
`row["id"]!.decode(Int.self)` can trap if a column is missing. A throwing
by-name API would make schema mismatches catchable.

## Type System

The decoding surface is:

- `PostgresDecodable`
- `PostgresCell.decode(_:)`
- `PostgresCell.decodeIfPresent(_:)`

Supported built-in type families:

- booleans;
- signed integers;
- floats/doubles;
- strings/text/json/jsonb;
- bytea as `[UInt8]` and `Data`;
- UUID;
- date/timestamp/timestamptz as `Date`;
- numeric as `Decimal`.

Text parameters are sent through `PostgresEncodable`.

Current parameter encoding:

- parameters are sent in text format;
- `postgresTypeOID` exists as a hint surface, but unnamed parse currently lets
  PostgreSQL infer types by default.

Important review notes:

- Binary `numeric` decoding should defensively reject malformed negative digit
  counts and out-of-range values.
- Text timestamp parsing is intentionally small and does not fully cover all
  PostgreSQL date/time forms.
- Decode errors currently include a hex preview of raw bytes.

## Wire Layer

### `ByteWriter`

Writes PostgreSQL wire values:

- UInt8
- Int16
- Int32
- raw bytes
- UTF-8 string
- NUL-terminated C string

All integer writes are big-endian.

### `ByteReader`

Reads from message payloads with bounds checks. Underflow throws
`PerunError.protocolViolation` rather than trapping.

### `FrontendMessage`

Builds client messages:

- StartupMessage
- SSLRequest
- CancelRequest
- Query
- Password/SASL messages
- Parse
- Bind
- Describe
- Execute
- Close
- Sync
- Terminate

Notable guard:

- Parse/Bind count fields are encoded as unsigned 16-bit values on the wire.
  Counts above 65535 throw `PerunError.tooManyParameters`.

### `BackendMessage`

Decodes server messages:

- Authentication
- ParameterStatus
- BackendKeyData
- ReadyForQuery
- RowDescription
- DataRow
- CommandComplete
- EmptyQueryResponse
- ErrorResponse
- NoticeResponse
- ParseComplete
- BindComplete
- CloseComplete
- NoData
- ParameterDescription
- PortalSuspended
- NotificationResponse
- Unknown messages

`ReadyForQuery` carries transaction status:

- idle
- in transaction
- in failed transaction
- unknown byte

Important review note: transaction status is decoded but not yet used by the
pool to quarantine/discard connections returned in transaction or failed
transaction state.

## Framing And Read Buffering

`PostgresConnection.readMessage()` reads:

```text
1-byte tag
4-byte length
payload
```

Message length validation:

- length must be at least 4;
- payload must be at most `ConnectionConfiguration.maxMessageSize`;
- default max payload is 256 MiB.

`readExactly(_:)` keeps a read-ahead buffer with an offset cursor. It requests at
most `readChunkSize` bytes per socket/TLS receive call, currently 65,536 bytes.

Important performance note: payload slices are copied out of `readBuffer`.
Socket/TLS receive currently allocate zero-filled arrays before reading.

## Socket And Blocking I/O

`SystemSocket` is a synchronous POSIX wrapper:

- DNS resolution through `getaddrinfo`;
- TCP socket creation and connect;
- `sendAll`;
- `receive`;
- `disconnect`;
- `shutdownBoth`.

`withBlockingIO(on:_:)` bridges synchronous calls into async/await by dispatching
them onto a dedicated queue. This keeps Swift concurrency cooperative threads
from being blocked by `connect`, `send`, `recv`, `SSL_read`, or `SSL_write`.

Important review note: `send` and `receive` capture fd/TLS state and then await
the I/O queue. They should guard closed state so requests queued after
`close()` fail cleanly rather than using a closed/recycled fd or freed TLS
object.

## Pool

`PostgresClient` is an actor that provides a bounded lazy pool.

State:

- `idle`: reusable connections;
- `openCount`: idle + checked out + connecting;
- `waiters`: continuations waiting for a connection;
- `isShutDown`.

Public API:

- `withConnection(_:)`
- `query(_:_:resultFormat:)`
- `shutdown()`
- `connectionCount`

Acquire behavior:

1. Fail if shut down.
2. Reuse idle connection if available.
3. Open a new connection if under capacity.
4. Otherwise enqueue a waiter.

Release behavior:

1. If shut down, close returned connection and decrement count.
2. If waiters exist, resume the first waiter with the connection.
3. Otherwise append to idle.

Error behavior:

- `PerunError.server` is treated as clean and reusable.
- Other errors close/drop the connection and may open a replacement for a waiter.

Important review notes:

- There is no transaction helper yet. `pool.query("BEGIN")` returns the
  connection to the pool while the transaction remains open.
- Pool release does not inspect `ReadyForQuery` transaction status.
- A replacement connection opened after an error should re-check shutdown before
  being handed to a waiter.

## Notifications And Notices

Notices:

- `onNotice(_:)` stores a handler.
- `NoticeResponse` messages call the handler during result collection or
  notification pumping.

LISTEN/NOTIFY:

- `listen(to:)` and `unlisten(from:)` quote identifiers and run SQL.
- `notifications` is an `AsyncStream<PostgresNotification>`.
- `waitForNotifications()` holds the wire lock and pumps the socket until
  cancelled or closed.

Important review note: the notification stream is currently unbounded. A capped
buffering policy would protect memory if the consumer is slow or absent.

## Cancellation

`cancelCurrentQuery()` uses backend PID/secret key received during startup.

Flow:

1. Read stored backend PID and secret key.
2. Open a separate TCP connection on a separate dispatch queue.
3. Send `CancelRequest`.
4. Close the side connection.

This avoids blocking behind the main connection's query receive loop.

## Error Model

`PerunError` covers:

- protocol violation;
- connection closed;
- structured server error;
- unsupported auth;
- local authentication failure;
- unexpected NULL;
- decode failure;
- TLS handshake failure;
- TLS I/O failure;
- TLS unavailable;
- pool shutdown;
- too many parameters.

Server errors are represented as `PostgresServerError`, preserving PostgreSQL
ErrorResponse fields and exposing common fields:

- severity;
- SQLSTATE;
- message;
- detail;
- hint.

## Tests

The current unit tests do not require a live PostgreSQL server.

### `CryptoTests`

Checks local primitives:

- Base64;
- SHA-256 vectors and multi-block hashing;
- HMAC-SHA-256;
- PBKDF2;
- MD5 vectors.

### `SCRAMTests`

Checks SCRAM-SHA-256 against RFC 7677-style vectors:

- client-first;
- client-final;
- server signature verification;
- signature mismatch rejection;
- nonce-prefix rejection.

### `WireTests`

Checks frontend message encoding:

- Bind text parameter;
- Bind null parameter;
- Sync frame length;
- Parse without parameter types;
- large parameter count encoded as unsigned 16-bit;
- too many parameters rejected.

### `FramingTests`

Checks backend message length validation:

- valid lengths;
- too-small lengths;
- oversized payloads.

### `TypeTests`

Checks typed decoding:

- integers;
- float/double;
- bool;
- UUID;
- bytea;
- timestamps/dates;
- numeric;
- jsonb binary header.

## Local Verification

Unit tests:

```bash
rtk swift test
```

Observed on 2026-07-07:

- 26 XCTest tests passed.
- No live PostgreSQL server needed.

Demo against PostgreSQL:

```bash
rtk swift run perun-demo
```

The demo reads:

- `PGHOST`
- `PGPORT`
- `PGUSER`
- `PGDATABASE`
- `PGPASSWORD`
- `PGSSLMODE`

## Review/Triage Pointers

`REVIEW.md` is a temporary working document from an adversarial review. It is
useful as a triage queue, but this project map should remain a stable technical
navigation document.

Already reflected in current code:

- H1: Parse/Bind parameter count overflow guard appears implemented.
- H2: Backend message payload size cap and receive chunk clamp appear
  implemented.

Still worth prioritizing:

- SCRAM exchange completion state.
- Guarding I/O after close.
- Pool transaction hygiene and transaction helper.
- Prepared statement ownership/global uniqueness.
- Binary numeric hardening.
- Safer by-name row API.
- Bounded notification stream.
- TLS default/security semantics.

## Where To Start When Changing Things

For protocol changes:

1. `Wire/FrontendMessage.swift`
2. `Wire/BackendMessage.swift`
3. `PostgresConnection.swift`
4. `WireTests.swift` / `FramingTests.swift`

For type decoding:

1. `Types/PostgresDecodable.swift`
2. `Types/ScalarTypes.swift`
3. `Types/FoundationTypes.swift`
4. `TypeTests.swift`

For authentication:

1. `PostgresConnection.handleAuthentication`
2. `Auth/SCRAM.swift`
3. `Crypto/*`
4. `SCRAMTests.swift` / `CryptoTests.swift`

For pooling/transactions:

1. `PostgresClient.swift`
2. `PostgresConnection.collectResults`
3. `BackendMessage.TransactionStatus`
4. Integration tests with live PostgreSQL will likely be needed.

For TLS/socket behavior:

1. `TLS/TLSConnection.swift`
2. `Socket/POSIXSocket.swift`
3. `Concurrency.swift`
4. `PostgresConnection.send/receive/forceClose`

