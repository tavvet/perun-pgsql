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
    RowStream.swift
    Copy.swift
    Timeout.swift
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
      SASLprep.swift
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
      TemporalTypes.swift
      NetworkTypes.swift
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
5. Send the startup packet. Each pinned default — `client_encoding=UTF8`, `DateStyle=ISO`,
   `IntervalStyle=postgres` — is added only if the caller's `runtimeParameters` didn't already
   set that GUC, matched **case-insensitively** (GUC names are), so `["datestyle": …]` replaces
   the pin instead of both keys landing in the packet with an order-dependent winner. The pins
   give the text decoders a known wire format regardless of the server / role / database
   default; a caller override still wins (a startup parameter overrides even an
   `ALTER ROLE … SET` default). Binary results don't depend on `DateStyle`/`IntervalStyle`, but
   `client_encoding` still governs string bytes in both formats.
6. Read backend messages until `ReadyForQuery`.
7. Return the initialized actor.

Failure path:

- Any error during TLS/startup calls `forceClose()`.
- `forceClose()` shuts down the fd, finishes the notification stream, then queues TLS/socket teardown.

### TLS Modes

Defined in `TLSMode`:

- `.disable`: never use TLS.
- `.allowPlaintextFallback`: request TLS, fall back to plaintext if server says no.
- `.encryptWithoutVerification`: require TLS encryption, but do not verify certificate/hostname.
- `.verifyFull`: require TLS and verify chain/hostname.

`TLSConnection.connect(fd:hostname:verifyFull:)` configures OpenSSL. SNI is set
for all TLS connections; certificate verification and hostname verification are
only enabled for `.verifyFull`.

`ConnectionConfiguration` defaults to `.verifyFull`. The unsafe modes are named
for the risk they carry; `PGSSLMODE=prefer` and `PGSSLMODE=require` are still
accepted by the demo/integration helpers and mapped onto the explicit Swift
cases.

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

SCRAM server-final signatures are verified before authentication can complete.
The signature comparison is constant-time for equal-length signatures. PBKDF2
uses a reusable HMAC-SHA-256 context so the HMAC key schedule is not rebuilt on
every iteration.

Passwords are prepared with SASLprep (RFC 4013) in `Auth/SASLprep.swift` before the
key derivation: map the RFC 3454 B.1/C.1.2 code points, apply Unicode NFKC (via
Foundation), and reject prohibited output — falling back to the original string on any
failure, exactly as PostgreSQL's `pg_saslprep` does so both sides derive the same key
(pure ASCII is unchanged). The bidirectional and unassigned-code-point checks are
skipped to match PostgreSQL. Tests cross-check our result against a real PostgreSQL SCRAM
verifier both ways: offline against a frozen vector (pinned every run) and live against a
fresh `pg_authid` row.

## Query Execution

Wire access is a **readers-writer lock** (`acquireShared` / `lock`), because the actor
alone is not enough — actors are reentrant across `await`, so without it two tasks could
interleave protocol messages on one socket.

- **Shared** — `query`, `prepare`, `execute`, `closePrepared`, and pipelined batches. Each
  is a single request (a batch is one contiguous write) delivered as one `PendingRead`, so
  they pipeline through the background reader and several can be in flight on one connection
  at once. Wire order keeps the reused unnamed statement/portal conflict-free, and a batch's
  bytes are contiguous, so a concurrent query can't interleave into its implicit transaction.
- **Exclusive** (`lock`) — transactions, `waitForNotifications`, and row streaming. These
  read inline over multiple requests (a transaction spans several; a stream is consumed over
  time), so they take exclusive access: it drains the in-flight shared queries and blocks new
  ones, owning the wire while the reader sits idle. Writer
  priority (shared waits while an exclusive holder is active or waiting) keeps exclusive
  access from starving. So `query`/`execute`/batches from other tasks wait for a BEGIN…COMMIT
  to finish rather than interleaving into it.

Both waiter kinds are cancellation-aware: cancelled before acquiring, a waiter is dropped
from its queue and throws `CancellationError` (it never touched the socket). Because a
hand-off reaches the actor asynchronously w.r.t. cancellation and can win the race after a
cancel, a granted-but-cancelled waiter re-checks `Task.isCancelled`, gives its access
back, and throws — so a cancelled task never proceeds holding the wire.

### Background response reader (transparent pipelining)

The shared paths do not read their own response inline. A caller takes shared access,
enqueues a `PendingRead`, writes its request without awaiting completion (`kickWrite` on
the write queue), and awaits its result; a background reader task (`readerLoop`) delivers
responses in FIFO order — the correlation, since v3 has no request IDs. So concurrent
autocommit queries on one connection are genuinely in flight together, and the reader
still matches each response to the right caller.

Reads run on a **separate dispatch queue** from writes, so the reader's blocking `recv`
can never starve a concurrent write. Exactly-once delivery: the reader pops each
`PendingRead` before running it, so teardown (`failAllPendingReads`) can't double-resume
the one in flight; a wire-desync error tears the connection down and fails everything
still queued (plus everyone parked for access, via `failAllAccessWaiters`).

Exclusive holders read inline, and the RW-lock guarantees the reader is idle whenever
they run (shared drained, new shared blocked), so the two read paths never contend for the
socket. What pipelining buys is latency (fewer round trips), not server-side parallelism —
one backend still runs the queries serially — and responses come back in order, so a slow
query head-of-line-blocks the ones behind it on the same connection. The pool remains the
mechanism for real concurrency.

Cancelling an **in-flight** query (already sent, so a parked waiter can't just be dropped)
is handled too: on cancellation `runReadOp` fires a `CancelRequest` — but only when the
server is running *this* query (`currentRead === op`), since `CancelRequest` is per-backend
and would otherwise cancel whichever query is running; a still-queued cancelled query is
let finish instead. Either way the response still drains through the reader (the wire stays
in sync), and `runReadOp` converts the outcome to `CancellationError`.

This is best-effort, as `CancelRequest` is — it races the query. The write is dispatched
asynchronously (`kickWrite` on the write queue), so a cancel can fire before the query even
reaches the server; and a query that already committed can't be un-run. `CancellationError`
means "we asked to cancel", not "the query did not execute" — so a side-effecting statement
may have committed. (Gating `CancelRequest` on the write having landed, or skipping the
write on a late cancel, would only narrow the window at the cost of an actor hop per query
or a new off-actor race — not a real guarantee, so it is documented rather than chased.)

`withTimeout(_:_:)` (`Timeout.swift`) builds on that cancellation: it races the operation
against a `Task.sleep` in a task group and cancels the loser (a `defer group.cancelAll()`, so
a fast operation doesn't wait out the deadline). On a timeout the operation task is cancelled —
for a query that fires the `CancelRequest` and drains to `ReadyForQuery` — and, because the
group awaits its children, that drain completes before `withTimeout` throws `PerunError.timedOut`.
So the connection is left in sync (the pool keeps it; `timedOut` is not a wire-desync error). It
is generic, composing over a bare query, a pool `query`, or a whole `withTransaction`.

For that last case the transaction path needs the same cancellation treatment as `runReadOp`,
because its body reads **inline** under exclusive access, not through the background reader.
`runInlineCancellable` wraps each transaction-*body* query (`runTransaction*`): a cancel fires a
`CancelRequest` (`cancelInlineInFlight`, `exclusiveHeld` + generation guarded), the inline read
drains, and the caller sees `CancellationError`. BEGIN/COMMIT/ROLLBACK are **not** wrapped, so
transaction control always completes — a timed-out transaction rolls back rather than committing.
Without this the inline read would ignore the cancel, wait out the query, and `withTransaction`
would `COMMIT`.

### Row streaming

`queryStream` returns a `PostgresRowStream` (an `AsyncSequence` of `PostgresRow`) that reads
a large result lazily instead of buffering it. It takes **exclusive** access — the stream
owns the wire until it ends, like a transaction — and reads inline over the extended protocol
with a **named portal** fetched in bounded chunks: `Execute(maxRows: chunkSize)` + `Flush` per
chunk, keeping the portal open across chunks (no `Sync`) so the implicit transaction spans the
whole stream. Rows are **pulled on demand** (`nextStreamRow`): each `for await` step reads until
one `DataRow` (return it), crossing chunk boundaries transparently — a `PortalSuspended` asks
for the next chunk, a `CommandComplete` closes the portal (`Close` + `Sync`) — until
`ReadyForQuery` ends it (`nil`). Backpressure is real: a slow consumer stops pulling, so the
socket buffer fills and the server blocks on its write. Memory is bounded to about one chunk.

Early termination is clean because chunking gives the server natural stop points: dropping the
stream (a `break`, or letting it go) runs `finishStream` from the `StreamCleanup` `deinit`,
which `Close`s the portal, `Sync`s, and drains the in-flight chunk (≤ `chunkSize` rows) to
`ReadyForQuery`, then frees the wire — so the connection is immediately reusable. A mid-stream
server error is handled the same way (drain to `ReadyForQuery`, then throw). `endStream`
releases the exclusive hold; a wire/IO failure tears the connection down instead. Streaming
inside `withTransaction` on the same connection would deadlock on `lock`, so it is a top-level
connection operation.

`nextStreamRow` is cancellation-aware, the same way autocommit queries are: the pull is wrapped
in `withTaskCancellationHandler`, and a cancel fires a `CancelRequest` (`cancelStreamInFlight`)
so a read blocked on a slow query — e.g. `pg_sleep` — unblocks instead of hanging until the
next backend message. It then runs `finishStream` and throws `CancellationError`. The same
`CancelRequest` fires on the pre-read fast path (a task already cancelled when the first pull
begins), so `finishStream`'s drain doesn't stall behind a still-running query either. A
`streamGeneration` guard makes a late cancel a no-op once its stream has ended (so it can never
cancel the query of a *later* stream that now holds the wire) — the streaming analogue of the
shared path's `currentRead === op` check. Without this, a cancelled `for await` on a slow
stream would keep the exclusive hold until the server replied.

### COPY

The COPY sub-protocol moves raw `CopyData` payloads in either direction under **exclusive**
access; the bytes are in the COPY statement's format (text/CSV/binary) and are opaque to the
driver — row formatting/parsing belongs to a higher layer. `Copy.swift` holds the public types.

- **COPY OUT** (`copyOut` → `PostgresCopyOutSequence`, an `AsyncSequence` of `[UInt8]`): send
  the `COPY … TO STDOUT` as a Simple Query, consume the `CopyOutResponse` handshake, then pull
  `CopyData` chunks (`nextCopyData`) until `CopyDone` → `CommandComplete` → `ReadyForQuery`
  (no `Sync` — it's Simple Query). It mirrors row streaming exactly: pull-based backpressure,
  cancellation-aware (`withTaskCancellationHandler` + `CancelRequest`), and a `CopyOutCleanup`
  `deinit` that stops an abandoned copy. Because COPY has no chunked pause, early termination
  and cancel both fire a `CancelRequest` (the server would otherwise stream the whole relation)
  and drain to `ReadyForQuery`.
- **COPY IN** (`copyIn(_:_:)`, closure-driven): send the `COPY … FROM STDIN`, consume the
  `CopyInResponse`, hand the closure a `PostgresCopyInWriter` whose `write`s are framed as
  `CopyData`, then `CopyDone` and read the result (`CommandComplete` "COPY n"). Throwing from
  the closure sends `CopyFail` (the server rolls the copy back) and rethrows the cause; the
  echoed error is drained and discarded. The writer carries a `copyInGeneration` token that
  `sendCopyData` checks against the connection's, so a writer used after its closure — or
  during a *later* `copyIn` on the same connection — is rejected rather than injecting bytes.
  No cancellation wrapper is needed — the caller drives the writes, so cancelling means
  throwing from the closure.

Each handshake reader rejects a **wrong-direction** statement instead of misbehaving: `copyOut`
of a `FROM STDIN` (the server would then wait for client data and the read would hang) aborts
the copy with `CopyFail`, drains, and throws; `copyIn` of a `TO STDOUT` (the server streams to
us — potentially the whole relation) fires a `CancelRequest`, drains, and throws. Both use a
shared `drainToReadyForQuery`.

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

- `runParameterizedQuery(_:_:parameterFormat:resultFormat:)`

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

Parameters are encoded as text by default. With `parameterFormat: .binary`,
values that provide `postgresBinary()` are sent in binary and the rest fall
back to text through per-parameter format codes. Result columns can be requested
as text or binary.

### Prepared Statements

Entry points:

- `runPrepare(_:)`
- `runExecute(_:_:parameterFormat:resultFormat:)`
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
- creating connection ID.

Execution sends:

```text
Bind unnamed portal to named statement
Execute portal
Sync
```

Prepared statement names include the connection ID plus a per-connection
counter. `execute` and `closePrepared` validate the handle's creating
connection ID before sending it to the server, so prepared-statement handles are
scoped to the backend connection that created them.

### Pipelining

Entry points on `PostgresConnection`, in two shapes — one prepared statement over many
parameter sets, or a heterogeneous batch of `PostgresQuery` (each its own SQL, params
and formats):

- `pipeline(_:_:parameterFormat:resultFormat:)` / `pipeline(_ queries:)` → `[QueryResult]`
- `pipelineIndependently(_:_:…)` / `pipelineIndependently(_ queries:)` → `[Result<QueryResult, Error>]`

All send every message before reading any reply — one round trip instead of `N`. A batch
is a single request (one contiguous write) delivered as one `PendingRead`, so it takes
shared access like a plain query: it pipelines with other queries, and its bytes stay
contiguous on the wire, so its implicit transaction can't be interleaved. The frontend
differs by shape — `FrontendMessage.pipelinedExecute` emits `Bind`/`Execute` per set
against the already-parsed statement; `pipelinedQueries` emits a full
`Parse`/`Bind`/`Describe`/`Execute` per query against the unnamed statement/portal — but
both share the readers, and the `Sync` placement is the only difference between the modes:

- **Atomic** (`pipeline`): one trailing `Sync`, so the server runs the batch as a
  single implicit transaction. `collectPipelinedResults` reads one `QueryResult` per
  `CommandComplete` up to the single `ReadyForQuery`; on any error it throws and drops
  the partial results (the transaction rolled back).
- **Independent** (`pipelineIndependently`): a `Sync` after each set, so each is its own
  unit. The single-result reader runs once per set, wrapping each outcome in a
  `Result`; a server error there leaves the wire in sync for the next set, while a
  wire-desync error propagates and aborts the batch.

Constraints, both from sending everything before reading: a set cannot depend on an
earlier set's result (parameters are known up front), and combined replies must fit the
socket buffers (bulk `INSERT`/`UPDATE`, not large result sets) or the batch can deadlock.

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
- throwing name access: `try row.cell("id")`
- throwing by-name decoding: `try row.decode("id", as: Int.self)`
- nullable by-name decoding: `try row.decodeIfPresent("nickname", as: String.self)`

Missing columns throw `PerunError.columnNotFound`; SQL NULL remains distinct and
is handled by `decodeIfPresent`. Name lookup uses a column-name index shared by
all rows in a `QueryResult`; duplicate column names keep first-match behavior.

## Type System

The decoding surface is:

- `PostgresDecodable`
- `PostgresCell.decode(_:)`
- `PostgresCell.decodeIfPresent(_:)`

Supported built-in type families:

- booleans;
- signed integers;
- floats/doubles;
- strings/text;
- json/jsonb as `String` or `PostgresJSON`;
- bytea as `[UInt8]` and `Data`;
- UUID;
- date/timestamp/timestamptz as `Date`;
- interval as `PostgresInterval` (months/days/microseconds), time as `PostgresTime`
  (microseconds since midnight), and timetz as `PostgresTimeTz` (time + east-of-UTC offset) —
  `TemporalTypes.swift`, text and binary;
- inet/cidr as `PostgresInet` (address bytes + prefix + `isCIDR`) — `NetworkTypes.swift`, text
  (an IPv6 parser handles `::` compression and embedded IPv4) and binary;
- numeric as `Decimal`;
- arrays of any of the above (`decodeArray`, any number of dimensions).

Parameters are sent through `PostgresEncodable`.

- By default they are sent in **text** format; unnamed `Parse` lets PostgreSQL
  infer the types.
- With `parameterFormat: .binary`, each value that implements `postgresBinary()`
  is sent in binary and `Parse` declares its `postgresTypeOID`; values without a
  binary form fall back to text (per-parameter format codes). Binary encoders are
  provided for the integer, floating-point, `Bool`, `String`, `UUID`, `Date`
  (timestamptz), `Data`/`[UInt8]` (bytea), `Decimal` (numeric) and `PostgresJSON`
  (json/jsonb) types.
- Arrays are sent through `PostgresArray` (any `PostgresEncodable` elements, `nil` for
  NULL) in any number of dimensions: a flat row-major element list plus a `dimensions`
  shape, with ergonomic initializers for 1-D (`[Element]`) and 2-D (`[[Element]]`) and an
  explicit `init(dimensions:elements:elementTypeOID:)` for higher. It renders nested `{…}`
  braces (one level per dimension), or the binary array wire format — `ndim`/flags/
  element-OID header, per-dimension length/lower-bound, then row-major length-framed
  elements — when every element has a binary form.
- Array *columns* decode through `decodeArray` on cells and rows (arrays can't use the
  `PostgresDecodable` protocol without clashing with the `[UInt8]` bytea decoder). A
  parser handles both wire formats — recursive descent for the `{…}` text form (including
  the `[lower:upper]=` dimension decoration PostgreSQL prints when a lower bound isn't 1),
  header + row-major elements for binary — producing flat elements plus a dimension list.
  A recursive `PostgresArrayDecodable` protocol (conformed by `Array` for each nesting
  level, `Optional` for a nullable leaf, and every scalar `PostgresDecodable` as a leaf)
  then reshapes them into `[T]`, `[[T]]`, `[[[T]]]` and deeper; the nesting depth is
  checked against the dimensions (a mismatch throws). `[UInt8]` (bytea) is itself an
  `Array`, so it can't also be a leaf — decode a `bytea[]` column into `[Data]`. Text
  elements get their type OID from the array-OID reverse map; binary carries it in the
  header. (Swift arrays are 0-based, so the lower bound is dropped.) Malformed input is
  rejected rather than silently truncated: the reshape must consume exactly the parsed
  elements (catching a ragged array like `{{1},{2,3}}`), and neither parser tolerates
  trailing bytes past the last binary element or content past the closing text brace.

Implementation notes:

- Binary `numeric` decoding defensively rejects malformed negative digit counts
  and out-of-range values.
- Text timestamp parsing is intentionally small and does not fully cover all
  PostgreSQL date/time forms.
- Decode errors report byte length but do not include raw byte previews by
  default. A compile-time `PERUN_ENABLE_DECODE_ERROR_BYTE_PREVIEW` flag can
  enable the preview while debugging.
- Scalar integer text decoders parse ASCII bytes directly. Floating-point text
  uses the standard library's correctly-rounded `Double`/`Float` string parser,
  so PostgreSQL's shortest float text round-trips exactly.

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

Extended-query batches are built into one `ByteWriter` with in-place frame
length back-patching:

- `parameterizedQuery(query:parameters:resultFormat:)`
- `prepare(statement:query:)`
- `execute(statement:parameters:resultFormat:)`
- `closeAndSync(_:name:)`

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

The pool uses this status on release: only idle connections are returned to the
idle list; connections still inside a transaction or failed transaction are
discarded.

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

`readSlice(_:)` keeps a read-ahead buffer with an offset cursor. It requests at
most `readChunkSize` bytes per socket/TLS receive call, currently 65,536 bytes,
and decodes backend message payloads through `ArraySlice` views into that
buffer.

Socket/TLS receive uses uninitialized buffers and sets the initialized count
from the actual `recv`/`SSL_read` return value.

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

`send` and `receive` check closed state before queueing blocking I/O, so calls
made after `close()` fail with `PerunError.connectionClosed` instead of using a
closed/recycled fd or freed TLS object.

## Pool

`PostgresClient` is an actor that provides a bounded lazy pool.

State:

- `idle`: reusable connections, each tagged with an `idleSince` timestamp;
- `openCount`: idle + checked out + connecting;
- `waiters`: continuations waiting for a connection;
- `isShutDown`;
- `maxConnectionLifetime` / `maxIdleTime` (optional recycling limits) and the `reaperTask`.
  Connections carry a `nonisolated createdAt` so the pool can judge age without an actor hop.

Public API:

- `withConnection(_:)`
- `query(_:_:parameterFormat:resultFormat:)`
- `shutdown()`
- `connectionCount`

Acquire behavior:

1. Fail if shut down.
2. Reuse an idle connection — but **vet it first**. A cheap synchronous age check
   (`isExpired`) drops one past `maxConnectionLifetime` (since `createdAt`) or `maxIdleTime`
   (since `idleSince`) and tries the next. Otherwise **validate it's alive** (`isProbablyAlive`):
   the server may have closed it while it sat idle (a shutdown, `pg_terminate_backend`, or an
   idle timeout leaves a termination `ErrorResponse` + socket close the parked reader never saw).
   The probe
   is a cheap non-blocking `MSG_PEEK` (`SystemSocket.isQuiescentOpen`, run on the read queue so
   it can't race the reader): a drained connection has nothing waiting, so `EWOULDBLOCK` means
   healthy, while EOF or unexpected pending bytes means dead. A dead one is discarded
   (`openCount -= 1`, closed) and the next idle connection is tried, so a borrower never gets a
   connection whose first query would fail. Best-effort — it can still die right after — with
   the borrower's own error path as the backstop; TLS is probed at the TCP level.
3. Open a new connection if under capacity.
4. Otherwise enqueue a waiter. An enqueued waiter is cancellation-aware — the same
   pattern as the wire lock: if its task is cancelled it leaves the queue and
   `acquire()` throws `CancellationError` (it never held a slot). Because `release()`
   hands a connection off asynchronously w.r.t. cancellation, a handoff can win the
   race after a cancel; so a waiter resumed with a connection re-checks
   `Task.isCancelled` and, if cancelled, returns the connection to the pool and throws
   rather than running on it.

Release behavior:

1. If shut down, close returned connection and decrement count.
2. If it came back mid-transaction, or is past `maxConnectionLifetime`, discard-and-replace it
   instead of reusing it.
3. If waiters exist, resume the first waiter with the connection.
4. Otherwise append to idle (tagged with `idleSince`).

Error behavior:

- Only errors that may have desynchronized the wire (connection closed, protocol
  violation, TLS failures) drop the connection and may open a replacement.
- Server (SQL) errors, decode/local errors and errors from the caller's closure
  leave the wire synchronized, so the connection is reused (release() still
  discards it if it came back inside a transaction).
- The split is `PerunError.mayHaveDesynchronizedWire`, an exhaustive switch over
  every error case (so a new case forces a decision).

Age-based recycling (opt-in; both limits default to nil):

- `maxConnectionLifetime` bounds how long a connection lives (since `createdAt`);
  `maxIdleTime` closes one that has sat idle too long. Enforced in three places: `acquire`
  drops an expired connection on borrow; `release` recycles one past its lifetime rather than
  reuse it — crucially *before* a direct handoff to a waiter, which would otherwise skip the age
  check and let lifetime slip under sustained load (idle time doesn't apply there — the
  connection wasn't idle); and a background `reaperTask` — started lazily on first checkout when
  a limit is set, cancelled on `shutdown` — scans `idle` every ~half the smallest limit (min
  500 ms) and closes expired ones. `release` routes an expired connection through
  `discardAndReplaceIfNeeded` (close + open a replacement for a waiter, if any); the reaper just
  closes them (idle connections have no waiters). The pool is lazy (no minimum idle count), so it
  can shrink to zero and reopen on demand. Timestamps use `ContinuousClock` (counts real elapsed
  time, matching the server's view).

Transaction hygiene:

- `withTransaction` keeps one connection checked out and wire-locked until
  COMMIT or ROLLBACK completes.
- Pool release checks `ReadyForQuery` transaction status and discards
  connections that are still inside a transaction or failed transaction.
- Replacement connections opened for waiters re-check shutdown before being
  handed out.

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
- The stream uses `.bufferingNewest(configuration.notificationBufferLimit)`;
  the default limit is 1024 notifications.

If the consumer is slow or absent, older buffered notifications are dropped in
favor of newer ones instead of growing memory without bound.

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

Server errors are represented as `PostgresServerError`, preserving every PostgreSQL
ErrorResponse field and exposing the common ones by name:

- severity;
- `sqlState` — a typed `SQLState` condition (unique / foreign-key / not-null / check
  violations, deadlock, serialization failure, …), with `.other(code)` for unnamed
  codes; `sqlStateCode` gives the raw five-character string, and class helpers
  (`isIntegrityConstraintViolation`, `isTransactionRollback`) cover whole classes;
- message, detail, hint;
- constraint / schema / table / column / data-type names, and error position.

`PerunError.serverError` bridges to it, so a caller can branch on
`error.serverError?.sqlState == .uniqueViolation` without unwrapping the case by hand.
SQLSTATE is the stable signal to switch on; `message` is localized and must not be
parsed. Mapping a condition to a domain error stays above the driver.

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

### `SASLprepTests`

SASLprep (RFC 4013) password preparation: ASCII left unchanged, RFC 4013 mapping and NFKC
examples, non-ASCII spaces mapped to space, "mapped to nothing" removed, compatibility
normalization, and prohibited-output fallback to the original. Two interop checks recompute the
SCRAM verifier from a non-identity password and match it against PostgreSQL's: one **offline**
against a frozen verifier captured from a live server (so interop is pinned on every run, no
server needed — the salt is embedded, so the recomputation is deterministic), and one **live**
against a freshly generated `pg_authid` verifier.

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

### `ErrorClassificationTests`

Checks `PerunError.mayHaveDesynchronizedWire`: wire-desync errors flag the pooled
connection for discard, local/server errors keep it. Covers every `PerunError` case.

### `ServerErrorTests`

Typed `SQLState` (code ↔ condition round-trip, `.other` for unnamed codes, class
helpers) and the `PostgresServerError` field accessors (constraint / table / position).
Plus a live check that a real unique violation surfaces as `.uniqueViolation` with its
constraint name and leaves the connection usable (skipped unless `PERUN_PGSQL_INTEGRATION=1`).

### `EncodingTests`

Parameter encoding: byte-exact text and binary wire form for each encodable type —
including multi-dimensional arrays (nested `{…}` braces and the multi-dimension binary
header) — plus the `Bind` message layout when binary parameters are requested.

### `TemporalTypesTests`

`PostgresInterval`, `PostgresTime`, and `PostgresTimeTz`: text/binary encode and decode
(byte-exact binary, the `intervalstyle=postgres` text parser, sub-second sign, the timetz
seconds-west zone), plus a live round-trip in both result formats, decoding a server-produced
interval, and an `interval[]` array.

### `NetworkTypesTests`

`PostgresInet`: IPv4/IPv6 text parsing and formatting (`::` compression, embedded IPv4, invalid
inputs), binary and text encode/decode, and a live round-trip of `inet`/`cidr` in both address
families and result formats, plus a server-produced value and an `inet[]` array.

### `TimeoutTests`

`withTimeout`: the wrapper fires on a slow operation and a fast one returns without waiting out
the deadline (offline); live, a timed-out query is cancelled server-side promptly (well under
`pg_sleep`) and the connection — direct or pooled — is left in sync and reusable. A timed-out
`withTransaction` is cancelled promptly too and **rolls back** (its INSERT does not persist),
guarding against the inline-read path silently committing.

### `ArrayDecodingTests`

Array-column decoding: the text and binary parsers (quoting, escapes, NULLs, 2-D and 3-D),
dimensionality mismatches, malformed-array rejection (ragged, trailing bytes/content), and a
live round-trip (1-D int, text with commas/NULLs, 2-D, 3-D, a binary result, multi-dimensional
`PostgresArray` parameters round-tripped as text and binary, and encode-via-`PostgresArray`
then decode back).

### `PipelineTests`

The pipelined-batch `Sync` placement at the wire level, for both shapes — prepared-bulk
(`Bind`/`Execute` per set) and heterogeneous (`Parse`/`Bind`/`Describe`/`Execute` per
query) — atomic vs independent. Plus live semantics: atomic bulk insert, atomic rollback
on error, independent partial success, and a heterogeneous batch whose trailing `SELECT`
sees the batch's own prior inserts (skipped unless `PERUN_PGSQL_INTEGRATION=1`).

### `ConfigurationTests`

`ConnectionConfiguration` defaults (verify-full TLS, bounded notification buffer, …).

### `ResultTests`

`PostgresRow` access: by-name lookup, throwing `cell`/`decode`, `columnNotFound`.

### Integration tests (live server)

Skipped unless `PERUN_PGSQL_INTEGRATION=1`; they require a live PostgreSQL and `PG*`
environment variables.

- `PreparedStatementIntegrationTests`: a prepared-statement handle is rejected on a
  different connection.
- `TransactionIntegrationTests`: commit/rollback; the pool discards open-transaction
  connections; shutdown does not leak a concurrently released connection; a healthy
  connection is reused after a local (non-wire) error.
- `BinaryParameterIntegrationTests`: round-trip of binary parameters (integers, floats,
  bool, text, UUID, timestamptz, bytea, numeric, json/jsonb, arrays), NULL parameters
  and binary results.
- `CancellationIntegrationTests`: cancelling a task parked for a pool slot or for the
  wire lock fails it with `CancellationError` and leaves the pool / connection usable;
  includes a looped test that races a cancel against a pool hand-off (proven to catch a
  missing re-check); and cancelling an in-flight query stops it early via `CancelRequest`.
- `PipeliningIntegrationTests`: concurrent queries / executes on one connection each get
  their own reply (correlation under pipelining); a batch pipelines with queries yet stays
  atomic; and a transaction pins a concurrent query out until it commits.
- `StreamingIntegrationTests`: `queryStream` matches the buffered result across many chunks;
  parameters with a one-row chunk size; an empty result; an early `break` frees the wire and
  the connection is reusable; a mid-stream server error surfaces and leaves the connection in
  sync; and cancelling a task on a slow stream (`pg_sleep`) — both while blocked mid-read and
  before the first read — returns promptly (via `CancelRequest`) and frees the connection
  rather than waiting for the query.
- `PoolValidationIntegrationTests`: a healthy idle connection is reused (the liveness probe
  doesn't false-positive), and a connection the server terminates while idle
  (`pg_terminate_backend`) is detected on borrow, discarded, and replaced — the next query runs
  on a fresh backend instead of failing.
- `PoolRecyclingIntegrationTests`: an idle connection past `maxIdleTime` is reaped (the pool
  shrinks to zero and reopens on demand), a connection past `maxConnectionLifetime` is replaced
  (new backend PID) — including when it's handed to a waiting task rather than pooled — and with
  no limits set a connection is reused indefinitely.
- `SessionParameterIntegrationTests`: the driver pins `client_encoding`/`DateStyle`/
  `IntervalStyle`, a caller can override a pinned key (including with a lowercase, case-different
  key), and the pin overrides a role's non-default `DateStyle` (a text date still decodes
  correctly) — proving the startup pin beats an `ALTER ROLE … SET` default.
- `CopyIntegrationTests`: `copyOut` reproduces a table's data and a `COPY (query)`, an early
  `break` frees the connection, and a non-COPY statement is rejected; `copyIn` loads rows and
  reports the "COPY n" tag, round-trips with `copyOut`, rolls back and rethrows when the closure
  throws (`CopyFail`), and rejects a writer used after its closure. Wrong-direction guards:
  `copyOut` of a `FROM STDIN` is rejected without hanging, `copyIn` of a `TO STDOUT` is rejected
  without running the closure, and a stale writer is rejected mid-way through a later `copyIn`
  (its bytes never land).

## Local Verification

Unit tests:

```bash
rtk swift test
```

Observed:

- The unit suite passes with no live PostgreSQL server.
- The live integration tests pass against PostgreSQL 17 with
  `PERUN_PGSQL_INTEGRATION=1` (and `PG*`) set.

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
