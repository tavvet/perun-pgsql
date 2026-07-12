import Dispatch

/// How the connection should use TLS.
public enum TLSMode: Sendable, Equatable {
    /// Never use TLS.
    case disable
    /// Use TLS if the server offers it, otherwise fall back to plaintext.
    case allowPlaintextFallback
    /// Require TLS; the channel is encrypted but the certificate is not verified.
    case encryptWithoutVerification
    /// Require TLS and verify the certificate chain and hostname.
    case verifyFull

    @available(*, deprecated, renamed: "allowPlaintextFallback")
    public static var prefer: TLSMode { .allowPlaintextFallback }

    @available(*, deprecated, renamed: "encryptWithoutVerification")
    public static var require: TLSMode { .encryptWithoutVerification }
}

/// Which password-based authentication methods the client will accept from the server.
///
/// A guard against an authentication downgrade: an attacker able to influence the handshake
/// (e.g. under `.allowPlaintextFallback`, or a MITM under `.encryptWithoutVerification`) could
/// otherwise make the server request cleartext and capture the password, or request md5 and
/// capture an offline-crackable digest. Under the default `.verifyFull` TLS this is already
/// mitigated; tighten it when the TLS mode is relaxed. Analogous to libpq's `require_auth`.
public enum AuthenticationRequirement: Sendable, Equatable {
    /// Accept whatever the server asks for — SCRAM, md5, or cleartext. The default.
    case any
    /// Refuse cleartext password; accept md5 or SCRAM.
    case disallowCleartext
    /// Accept only SCRAM-SHA-256 (SASL); refuse md5 and cleartext.
    case scramOnly
}

/// Everything needed to open a connection.
public struct ConnectionConfiguration: Sendable {
    public var host: String
    public var port: UInt16
    public var user: String
    public var database: String
    public var password: String?
    /// How to negotiate TLS. Defaults to `.verifyFull`.
    public var tlsMode: TLSMode
    /// Which authentication methods to accept from the server. Defaults to `.any`; tighten it
    /// to forbid a cleartext/md5 downgrade when running under a relaxed TLS mode.
    public var authenticationRequirement: AuthenticationRequirement
    /// Bound on the whole connect — the TCP connection, TLS negotiation, and the startup/auth
    /// handshake — after which the socket is torn down (nil = no bound beyond the OS TCP default,
    /// ~75 s). Defaults to 10 seconds, so a blackholed or silent host fails fast instead of pinning
    /// a pool slot. The one exception is DNS resolution, which runs before the deadline is armed and
    /// is bounded only by the system resolver.
    public var connectTimeout: Duration?
    /// Reject any backend message whose payload exceeds this many bytes. Bounds
    /// memory against a malicious or buggy server that declares a huge length.
    /// Defaults to 256 MiB.
    public var maxMessageSize: Int
    /// Maximum number of LISTEN/NOTIFY messages buffered when the consumer is
    /// slower than the socket pump. Newer notifications replace older buffered
    /// ones once this limit is reached. Defaults to 1024.
    public var notificationBufferLimit: Int
    /// Extra startup parameters (e.g. `["application_name": "perun"]`). The driver also pins
    /// `client_encoding=UTF8`, `DateStyle=ISO` and `IntervalStyle=postgres` so its text
    /// decoders read a known format; set any of those keys here (any case) to override that
    /// default.
    public var runtimeParameters: [String: String]

    public init(host: String = "localhost",
                port: UInt16 = 5432,
                user: String,
                database: String,
                password: String? = nil,
                tlsMode: TLSMode = .verifyFull,
                authenticationRequirement: AuthenticationRequirement = .any,
                connectTimeout: Duration? = .seconds(10),
                maxMessageSize: Int = 256 * 1024 * 1024,
                notificationBufferLimit: Int = 1024,
                runtimeParameters: [String: String] = [:]) {
        precondition(notificationBufferLimit > 0, "notificationBufferLimit must be positive")
        self.host = host
        self.port = port
        self.user = user
        self.database = database
        self.password = password
        self.tlsMode = tlsMode
        self.authenticationRequirement = authenticationRequirement
        self.connectTimeout = connectTimeout
        self.maxMessageSize = maxMessageSize
        self.notificationBufferLimit = notificationBufferLimit
        self.runtimeParameters = runtimeParameters
    }
}

/// A thread-safe holder for the in-flight teardown Task of an abandoned copyOut or row stream. The
/// iterator's `deinit` writes it (from any thread, synchronously at the `break`); the pool's
/// `release()` (and `close()`) read and await it before touching the wire, so they observe the settled
/// outcome instead of racing the drain. Lives outside the actor because the `deinit` can't hop onto it
/// synchronously and the readers must not have to. Tagged with the teardown's generation so a stale
/// iterator's late `deinit` can't clobber a newer teardown's handle with its own (no-op) task.
final class TeardownBox: @unchecked Sendable {
    private let lock = POSIXLock()
    private var entry: (generation: UInt64, task: Task<Void, Never>)?
    /// Record `task` for `generation` unless a same-or-newer generation is already held — a late deinit
    /// from an older copy/stream must not replace the current teardown's handle.
    func record(generation: UInt64, task: Task<Void, Never>) {
        lock.withLock {
            if let entry, entry.generation >= generation { return }
            entry = (generation, task)
        }
    }
    func clear() { lock.withLock { entry = nil } }
    func currentTask() -> Task<Void, Never>? { lock.withLock { entry?.task } }
}

/// A single connection to a PostgreSQL server.
///
/// The connection is an `actor`, so its socket buffer and protocol state are
/// isolated — you can hold one from multiple tasks and calls are serialized.
/// Blocking socket I/O is pushed onto a dedicated dispatch queue via
/// `withBlockingIO`, keeping the cooperative pool unblocked.
public actor PostgresConnection {

    /// A scoped transaction running on one locked connection.
    ///
    /// Use the methods on this value inside `withTransaction`; they reuse the
    /// transaction's wire lock instead of trying to acquire it again.
    public struct Transaction: Sendable {
        private let connection: PostgresConnection
        private let contextID: Int

        fileprivate init(connection: PostgresConnection, contextID: Int) {
            self.connection = connection
            self.contextID = contextID
        }

        @discardableResult
        public func query(_ sql: String) async throws -> QueryResult {
            try await connection.runTransactionSimpleQuery(sql, contextID: contextID)
        }

        @discardableResult
        public func query(_ sql: String,
                          _ parameters: [(any PostgresEncodable)?],
                          parameterFormat: PostgresFormat = .text,
                          resultFormat: PostgresFormat = .text) async throws -> QueryResult {
            try await connection.runTransactionParameterizedQuery(sql, parameters,
                                                                  parameterFormat: parameterFormat,
                                                                  resultFormat: resultFormat,
                                                                  contextID: contextID)
        }

        public func prepare(_ sql: String) async throws -> PreparedStatement {
            try await connection.runTransactionPrepare(sql, contextID: contextID)
        }

        @discardableResult
        public func execute(_ statement: PreparedStatement,
                            _ parameters: [(any PostgresEncodable)?] = [],
                            parameterFormat: PostgresFormat = .text,
                            resultFormat: PostgresFormat = .text) async throws -> QueryResult {
            try await connection.runTransactionExecute(statement, parameters,
                                                       parameterFormat: parameterFormat,
                                                       resultFormat: resultFormat,
                                                       contextID: contextID)
        }

        public func closePrepared(_ statement: PreparedStatement) async throws {
            try await connection.runTransactionClosePrepared(statement, contextID: contextID)
        }
    }

    private let fd: Int32
    /// Writes (and connect/TLS setup) run here.
    private let ioQueue: DispatchQueue
    /// Reads run on their own queue so a blocking `recv` parked here can never
    /// starve a concurrent write on `ioQueue` — the prerequisite for a background
    /// reader that drains responses while callers keep writing.
    private let readQueue: DispatchQueue
    /// Remembered so `cancelCurrentQuery` can open a fresh connection.
    private let host: String
    private let port: UInt16
    /// Connect timeout, reused when `sendCancelRequest` opens its own socket.
    private let connectTimeout: Duration?
    /// The session's TLS mode, so a query cancel can secure its own connection the same way.
    private let tlsMode: TLSMode
    /// Reject backend messages whose payload exceeds this many bytes (DoS guard).
    private let maxMessageSize: Int
    /// Process-local identity used to keep prepared-statement handles scoped to
    /// the backend connection that created them.
    private let connectionID: UInt64

    /// The TLS channel, once negotiated. When non-nil, all I/O flows through it.
    private var tls: TLSConnection?

    /// Stream of asynchronous LISTEN/NOTIFY notifications from the server.
    /// When this connection was established (monotonic clock), so a pool can recycle it by
    /// age. `nonisolated` so the pool reads it without an actor hop; immutable across checkouts.
    nonisolated let createdAt: ContinuousClock.Instant
    public nonisolated let notifications: AsyncStream<PostgresNotification>
    private let notificationContinuation: AsyncStream<PostgresNotification>.Continuation

    /// Optional handler invoked for each NoticeResponse (warnings, etc.).
    private var noticeHandler: (@Sendable (PostgresServerError) -> Void)?

    /// Unconsumed bytes already read from the socket, plus a read cursor so we
    /// don't pay O(n) to drop consumed bytes on every message.
    private var readBuffer: [UInt8] = []
    private var readOffset: Int = 0

    /// Server runtime parameters (`server_version`, `client_encoding`, …),
    /// gathered from `ParameterStatus` messages.
    public private(set) var parameters: [String: String] = [:]

    /// Last transaction status reported by ReadyForQuery.
    private(set) var transactionStatus: TransactionStatus = .idle

    /// Whether this connection is running over an encrypted TLS channel.
    public var isSecure: Bool { tls != nil }

    /// The pool's release path needs the transaction status (to decide whether to keep the
    /// connection), whether it was torn down mid-use, and whether an abandoned `COPY … TO STDOUT` or
    /// row stream is still tearing down — both tear down in a detached `Task`, so at release time the
    /// wire can still be held (`copyOutActive` / `streamActive`) while `transactionStatus` reads a
    /// stale `.idle`. The pool must discard such a connection, not hand a waiter one whose teardown is
    /// still in flight.
    var releaseState: (status: TransactionStatus, isClosed: Bool, teardownActive: Bool) {
        (transactionStatus, isClosed, copyOutActive || streamActive)
    }

    #if DEBUG
    /// Test seam (debug builds only): invoked inside `copyIn` right after `CopyInResponse` is read
    /// but before the copy is marked active, so a test can cancel *deterministically* in the window
    /// `onCancelledAfterSuccess` covers instead of racing `cancel()` against the handshake.
    private var copyInHandshakeTestHook: (@Sendable () async -> Void)?
    func setCopyInHandshakeTestHook(_ hook: @escaping @Sendable () async -> Void) { copyInHandshakeTestHook = hook }
    #endif

    /// Backend PID + secret key, needed later to issue query cancellation.
    private var backendProcessID: Int32 = 0
    private var backendSecretKey: Int32 = 0

    private var isClosed = false

    /// In-flight SCRAM exchange state, held between authentication messages.
    private var scram: SCRAMClient?

    /// Monotonic counter for generating unique prepared-statement names.
    private var preparedStatementCounter = 0

    private var transactionContextCounter = 0
    private var activeTransactionContext: Int?

    private init(fd: Int32,
                 ioQueue: DispatchQueue,
                 host: String,
                 port: UInt16,
                 connectTimeout: Duration?,
                 tlsMode: TLSMode,
                 maxMessageSize: Int,
                 notificationBufferLimit: Int) {
        self.fd = fd
        self.ioQueue = ioQueue
        self.readQueue = DispatchQueue(label: "perun.connection.read")
        self.host = host
        self.port = port
        self.connectTimeout = connectTimeout
        self.tlsMode = tlsMode
        self.maxMessageSize = maxMessageSize
        self.connectionID = UInt64.random(in: UInt64.min ... UInt64.max)
        self.createdAt = ContinuousClock().now
        var continuation: AsyncStream<PostgresNotification>.Continuation!
        self.notifications = AsyncStream(bufferingPolicy: .bufferingNewest(notificationBufferLimit)) {
            continuation = $0
        }
        self.notificationContinuation = continuation
    }

    // MARK: - Connecting

    /// Open a TCP connection, perform the startup handshake, and return once the
    /// server reports it is ready for queries.
    public static func connect(_ configuration: ConnectionConfiguration) async throws -> PostgresConnection {
        let ioQueue = DispatchQueue(label: "perun.connection.io")
        let start = ContinuousClock().now
        let fd: Int32
        do {
            let timeout = configuration.connectTimeout
            fd = try await withBlockingIO(on: ioQueue) {
                try SystemSocket.makeConnected(host: configuration.host, port: configuration.port, timeout: timeout)
            }
        } catch let error as SocketError {
            throw PerunError.connectionFailed(error.description)   // one error type out of connect: PerunError
        }
        let connection = PostgresConnection(fd: fd, ioQueue: ioQueue,
                                            host: configuration.host, port: configuration.port,
                                            connectTimeout: configuration.connectTimeout,
                                            tlsMode: configuration.tlsMode,
                                            maxMessageSize: configuration.maxMessageSize,
                                            notificationBufferLimit: configuration.notificationBufferLimit)

        // One deadline for the whole connect (from `start`, so TCP time counts): a watchdog shuts
        // the socket down when it passes, unblocking any recv/send parked in TLS or startup/auth,
        // so the total handshake is bounded even against a peer that dribbles or withholds bytes.
        // It reports whether it fired; if it did — even in the rare case startup raced to finish at
        // the same instant — connect() discards the (now shut-down) connection and reports a
        // timeout, so a broken connection is never returned. Cancelled the moment we're ready.
        let watchdog: Task<Bool, Never>? = configuration.connectTimeout.map { timeout in
            Task {
                let remaining = timeout - (ContinuousClock().now - start)
                let capped = min(max(remaining, .zero), .seconds(Int64(Int32.max)))
                do { try await Task.sleep(for: capped) } catch { return false }   // cancelled before the deadline
                SystemSocket.shutdownBoth(fd: fd)
                return true                                                       // fired: the fd is shut down
            }
        }
        /// Stop the watchdog and report whether it had already fired.
        func stopWatchdog() async -> Bool {
            watchdog?.cancel()
            return await watchdog?.value ?? false
        }

        // The same absolute deadline the watchdog arms, handed to the startup path: the watchdog
        // shuts the socket to unblock a parked recv, but SCRAM's PBKDF2 is synchronous CPU work it
        // can't interrupt, so that step checks this deadline itself. Capped to avoid Instant overflow.
        let deadline = configuration.connectTimeout.map { start + min($0, .seconds(Int64(Int32.max))) }

        do {
            if configuration.tlsMode != .disable {
                try await connection.negotiateTLS(configuration)
            }
            try await connection.startup(configuration, deadline: deadline)
            if await stopWatchdog() {
                await connection.forceClose()
                throw PerunError.connectionFailed("connect timed out during the startup handshake")
            }
        } catch is KeyDerivationDeadlineExceeded {
            // The connect deadline passed inside SCRAM's PBKDF2. The socket is torn down, so report a
            // connection failure — not the query-oriented `.timedOut`, which promises a usable connection.
            _ = await stopWatchdog()
            await connection.forceClose()
            throw PerunError.connectionFailed("connect timed out during authentication")
        } catch {
            _ = await stopWatchdog()
            await connection.forceClose()
            throw error
        }
        return connection
    }

    /// Ask the server to upgrade to TLS before the startup handshake.
    private func negotiateTLS(_ configuration: ConnectionConfiguration) async throws {
        // Sent in cleartext — `tls` is still nil, so `send` uses the raw socket.
        try await send(FrontendMessage.sslRequest())
        let reply = try await receiveSSLResponseByte()
        switch reply {
        case UInt8(ascii: "S"):
            let fd = self.fd
            let host = configuration.host
            let verifyFull = configuration.tlsMode == .verifyFull
            let established = try await withBlockingIO(on: ioQueue) {
                try TLSConnection.connect(fd: fd, hostname: host, verifyFull: verifyFull)
            }
            self.tls = established
        case UInt8(ascii: "N"):
            if configuration.tlsMode == .encryptWithoutVerification || configuration.tlsMode == .verifyFull {
                throw PerunError.tlsNotAvailable
            }
            // .allowPlaintextFallback: carry on unencrypted.
        default:
            throw PerunError.protocolViolation("unexpected SSL negotiation reply: \(reply)")
        }
    }

    /// Read exactly one byte for the SSLRequest reply, without touching the
    /// message buffer (this byte precedes all framed messages).
    private func receiveSSLResponseByte() async throws -> UInt8 {
        let fd = self.fd
        let bytes = try await withBlockingIO(on: readQueue) {
            try SystemSocket.receive(fd: fd, maxLength: 1)
        }
        guard let byte = bytes.first else { throw PerunError.connectionClosed }
        return byte
    }

    // MARK: - Public API
    //
    // Every request acquires an internal async lock so its full request/response
    // cycle runs atomically on the wire. The actor is reentrant at each `await`,
    // so without this two overlapping calls from different tasks could interleave
    // their messages and corrupt the protocol stream.

    /// Run one Simple Query request. The string may contain multiple statements; the returned
    /// result is the last statement's — its rows and command tag together — matching libpq's
    /// `PQexec`.
    @discardableResult
    public func query(_ sql: String) async throws -> QueryResult {
        try await acquireShared(); defer { releaseShared() }
        return try await runReadOp(sending: FrontendMessage.query(sql)) {
            try await self.collectResults()
        }
    }

    /// Run a parameterized query over the extended protocol. `$1…$n` in the SQL
    /// are filled from `parameters`, safely — values are never spliced into the
    /// SQL text, so this is immune to SQL injection.
    ///
    /// `parameterFormat` selects how parameters are sent (`.text` default, or
    /// `.binary`); `resultFormat` selects how result columns come back. Decoded
    /// values (`row[...].decode(_:)`) are the same either way.
    @discardableResult
    public func query(_ sql: String,
                      _ parameters: [(any PostgresEncodable)?],
                      parameterFormat: PostgresFormat = .text,
                      resultFormat: PostgresFormat = .text) async throws -> QueryResult {
        try await acquireShared(); defer { releaseShared() }
        // No parameters and text results → Simple Query is one round trip lighter.
        if parameters.isEmpty && resultFormat == .text {
            return try await runReadOp(sending: FrontendMessage.query(sql)) {
                try await self.collectResults()
            }
        }
        let request = try FrontendMessage.parameterizedQuery(query: sql, parameters: parameters,
                                                             parameterFormat: parameterFormat,
                                                             resultFormat: resultFormat)
        return try await runReadOp(sending: request) {
            try await self.collectResults()
        }
    }

    /// Stream a query's rows instead of buffering the whole result set in memory.
    ///
    /// Returns a `PostgresRowStream` to consume with `for try await`. The rows are
    /// fetched from the server in bounded chunks (`chunkSize` rows per round trip) and
    /// delivered on demand, so a large result never has to fit in memory at once and a
    /// slow consumer throttles the server (rather than the reverse).
    ///
    /// The stream holds this connection's wire **exclusively** until it ends — like a
    /// transaction, no other query runs on the connection while a stream is open — so
    /// consume it promptly and don't start a stream inside `withTransaction` on the same
    /// connection. Stopping early (a `break` or an error) closes the portal and frees the
    /// wire. `$1…$n` parameters and `resultFormat` work exactly as in `query`.
    public func queryStream(_ sql: String,
                            _ parameters: [(any PostgresEncodable)?] = [],
                            parameterFormat: PostgresFormat = .text,
                            resultFormat: PostgresFormat = .text,
                            chunkSize: Int = 512) async throws -> PostgresRowStream {
        let chunk = Int32(clamping: max(1, chunkSize))
        try await lock()                         // exclusive; released when the stream ends
        do {
            guard !isClosed else { throw PerunError.connectionClosed }
            streamPortalCounter += 1
            let portal = "perun_stream_\(String(connectionID, radix: 16))_\(streamPortalCounter)"
            // Binary parameters need declared type OIDs; text lets the server infer.
            let typeOIDs: [Int32] = parameterFormat == .binary ? parameters.map { $0?.postgresTypeOID ?? 0 } : []
            var request = try FrontendMessage.parse(statement: "", query: sql, parameterTypeOIDs: typeOIDs)
            request += try FrontendMessage.bind(portal: portal, statement: "", parameters: parameters,
                                                parameterFormat: parameterFormat, resultFormat: resultFormat)
            request += FrontendMessage.describe(.portal, name: portal)
            request += FrontendMessage.execute(portal: portal, maxRows: chunk)
            request += FrontendMessage.flush()
            try await send(request)

            streamActive = true
            streamGeneration += 1
            streamPortal = portal
            streamChunkSize = chunk
            streamColumns = []
            streamColumnIndex = [:]
            streamTerminating = false
            streamPendingError = nil
            streamTeardownBox.clear()               // drop any prior stream's settled teardown handle
            return PostgresRowStream(connection: self, generation: streamGeneration)
        } catch {
            forceCloseIfDesynced(error)              // a failed send here leaves the wire out of sync
            unlock()
            throw error
        }
    }

    /// Stream the payload of a `COPY … TO STDOUT` as raw `CopyData` chunks — an
    /// `AsyncSequence` of `[UInt8]` in the COPY statement's format (text/CSV/binary),
    /// opaque to the driver. Like `queryStream` it holds the connection exclusively until
    /// consumed and frees it on early stop (`break`, error, or cancellation), which
    /// cancels the COPY server-side. `COPY (SELECT …) TO STDOUT` works too.
    public func copyOut(_ sql: String) async throws -> PostgresCopyOutSequence {
        try await lock()                         // exclusive; released when the copy ends
        do {
            guard !isClosed else { throw PerunError.connectionClosed }
            try await send(FrontendMessage.query(sql))
            // Cancellable like copyIn's handshake: a COPY parked before CopyOutResponse (e.g. on a
            // table lock) must not hold the wire uninterruptibly — a cancel fires a CancelRequest
            // and the response drains to ReadyForQuery. If instead the handshake *succeeded* and the
            // cancel lands in the race window before copyOutActive is set, the server is about to
            // stream CopyData that can't be stopped in band (and a CancelRequest may already be in
            // flight), so tear the connection down rather than leave rows on the wire.
            try await runInlineCancellable {
                try await self.readCopyOutResponse()
            } onCancelledAfterSuccess: {
                self.forceClose()
            }
            copyOutActive = true
            copyOutGeneration += 1
            copyOutTerminating = false
            copyOutPendingError = nil
            copyOutTeardownBox.clear()               // drop any prior copy's settled teardown handle
            return PostgresCopyOutSequence(connection: self, generation: copyOutGeneration)
        } catch {
            forceCloseIfDesynced(error)              // readCopyOutResponse desynced: don't leave it open
            unlock()
            throw error
        }
    }

    /// Bulk-load rows with `COPY … FROM STDIN`. The `write` closure receives a
    /// `PostgresCopyInWriter` and pushes payload chunks in the COPY statement's format
    /// (text/CSV/binary); returning normally finishes the copy (`CopyDone`) and the result's
    /// command tag reports the row count. Throwing from the closure aborts the copy
    /// (`CopyFail`, so the server rolls it back) and rethrows. Holds the connection
    /// exclusively for the duration.
    ///
    /// ```swift
    /// try await connection.copyIn("COPY people (id, name) FROM STDIN") { writer in
    ///     for person in people { try await writer.write("\(person.id)\t\(person.name)\n") }
    /// }
    /// ```
    @discardableResult
    public func copyIn(_ sql: String,
                       _ write: @Sendable (PostgresCopyInWriter) async throws -> Void) async throws -> QueryResult {
        try await lock()
        defer { unlock() }
        do {
            guard !isClosed else { throw PerunError.connectionClosed }
            try await send(FrontendMessage.query(sql))
            // Both inline reads are cancellable: a COPY parked before CopyInResponse (waiting on a
            // table lock, say) or a slow post-CopyDone completion would otherwise hold the wire
            // uninterruptibly. A cancel fires a CancelRequest, the server aborts, and the response
            // drains to ReadyForQuery — the connection stays reusable and the caller sees the cancel.
            // If instead the handshake *succeeded* and the cancel lands in the race window before
            // copyInActive is set, the server is now in copy-in mode; abandoning that would leave the
            // wire mid-COPY (and a CancelRequest may already be in flight), so tear the connection
            // down rather than hand it back desynchronised.
            try await runInlineCancellable {
                try await self.readCopyInResponse()
                #if DEBUG
                await self.copyInHandshakeTestHook?()   // no-op unless a test installed a seam
                #endif
            } onCancelledAfterSuccess: {
                self.forceClose()
            }

            copyInActive = true
            copyInGeneration += 1
            do {
                try await write(PostgresCopyInWriter(connection: self, generation: copyInGeneration))
            } catch {
                copyInActive = false
                // Abort the copy, but keep the closure's error as the reported cause even if the
                // abort's own drain fails — only tearing down then, if that drain desynced the wire.
                do { try await failCopyIn() } catch let drainError { forceCloseIfDesynced(drainError) }
                throw error
            }
            copyInActive = false
            try await send(FrontendMessage.copyDone())
            return try await runInlineCancellable { try await self.collectResults() }   // "COPY n" + ReadyForQuery
        } catch {
            forceCloseIfDesynced(error)              // an inline reader must not leave a desynced wire open
            throw error
        }
    }

    /// Parse a statement once so it can be executed repeatedly with different
    /// parameters. The server reports the parameter and result types up front.
    public func prepare(_ sql: String) async throws -> PreparedStatement {
        try await acquireShared(); defer { releaseShared() }
        let name = nextStatementName()
        let request = try FrontendMessage.prepare(statement: name, query: sql)
        return try await runReadOp(sending: request) {
            try await self.readPrepareResult(name: name)
        }
    }

    /// Execute a prepared statement with the given parameters.
    @discardableResult
    public func execute(_ statement: PreparedStatement,
                        _ parameters: [(any PostgresEncodable)?] = [],
                        parameterFormat: PostgresFormat = .text,
                        resultFormat: PostgresFormat = .text) async throws -> QueryResult {
        try validatePreparedStatement(statement)
        try validateBinaryParameterTypes(statement, parameters, parameterFormat: parameterFormat)
        try await acquireShared(); defer { releaseShared() }
        let request = try FrontendMessage.execute(statement: statement.name, parameters: parameters,
                                                  parameterFormat: parameterFormat, resultFormat: resultFormat)
        let columns = preparedResultColumns(statement, resultFormat: resultFormat)
        return try await runReadOp(sending: request) {
            try await self.collectResults(initialColumns: columns)
        }
    }

    /// Pipeline one prepared statement over many parameter sets as a single **atomic**
    /// batch: all the `Bind`/`Execute` messages are sent without waiting for replies,
    /// then the results are read in order. Because they share one trailing `Sync`, the
    /// server runs them in a single implicit transaction — if any set fails the whole
    /// batch rolls back and this throws. Results come back one per set, in order.
    ///
    /// The win is latency: `N` sets cost one round trip instead of `N`. Two limits
    /// follow from sending everything before reading anything: a set cannot depend on
    /// an earlier set's result (all parameters are known up front), and the batch
    /// should have small per-command results (bulk `INSERT`/`UPDATE`) — a batch whose
    /// combined replies exceed the socket buffers can deadlock.
    @discardableResult
    public func pipeline(_ statement: PreparedStatement,
                         _ parameterSets: [[(any PostgresEncodable)?]],
                         parameterFormat: PostgresFormat = .text,
                         resultFormat: PostgresFormat = .text) async throws -> [QueryResult] {
        try validatePreparedStatement(statement)
        for set in parameterSets { try validateBinaryParameterTypes(statement, set, parameterFormat: parameterFormat) }
        guard !parameterSets.isEmpty else { return [] }
        try await acquireShared(); defer { releaseShared() }
        return try await runPipelinedExecute(statement, parameterSets,
                                             parameterFormat: parameterFormat, resultFormat: resultFormat,
                                             syncAfterEach: false)
    }

    /// Like `pipeline`, but each parameter set is its own autocommit unit (a `Sync`
    /// after each), so a failure in one neither rolls back nor skips the others.
    /// Returns a per-set `Result`, in order. Still throws for a wire-level failure,
    /// which aborts the whole batch.
    public func pipelineIndependently(_ statement: PreparedStatement,
                                      _ parameterSets: [[(any PostgresEncodable)?]],
                                      parameterFormat: PostgresFormat = .text,
                                      resultFormat: PostgresFormat = .text) async throws -> [Result<QueryResult, Error>] {
        try validatePreparedStatement(statement)
        for set in parameterSets { try validateBinaryParameterTypes(statement, set, parameterFormat: parameterFormat) }
        guard !parameterSets.isEmpty else { return [] }
        try await acquireShared(); defer { releaseShared() }
        return try await runPipelinedExecuteIndependently(statement, parameterSets,
                                                          parameterFormat: parameterFormat, resultFormat: resultFormat)
    }

    /// Pipeline a heterogeneous batch of queries (each its own SQL and parameters) as
    /// one **atomic** batch — the same all-or-nothing semantics as the prepared-bulk
    /// `pipeline`, but the commands may differ. Results come back in order. The same
    /// limits apply: a query cannot depend on an earlier query's result, and combined
    /// replies must stay small enough to fit the socket buffers.
    @discardableResult
    public func pipeline(_ queries: [PostgresQuery]) async throws -> [QueryResult] {
        guard !queries.isEmpty else { return [] }
        try await acquireShared(); defer { releaseShared() }
        return try await runPipelinedQueries(queries, syncAfterEach: false)
    }

    /// Like `pipeline([PostgresQuery])`, but each query is its own autocommit unit; a
    /// failure in one doesn't roll back or skip the others. Returns a per-query `Result`.
    public func pipelineIndependently(_ queries: [PostgresQuery]) async throws -> [Result<QueryResult, Error>] {
        guard !queries.isEmpty else { return [] }
        try await acquireShared(); defer { releaseShared() }
        return try await runPipelinedQueriesIndependently(queries)
    }

    /// Release a prepared statement's server-side resources.
    public func closePrepared(_ statement: PreparedStatement) async throws {
        try validatePreparedStatement(statement)
        try await acquireShared(); defer { releaseShared() }
        _ = try await runReadOp(sending: FrontendMessage.closeAndSync(.statement, name: statement.name)) {
            try await self.collectResults()
        }
    }

    /// Run `body` inside a SQL transaction on this connection.
    ///
    /// It holds the wire exclusively for the whole transaction, so no other task can
    /// interleave or pipeline a statement between `BEGIN` and `COMMIT` / `ROLLBACK`.
    public func withTransaction<T: Sendable>(
        _ body: @Sendable (Transaction) async throws -> T
    ) async throws -> T {
        try await lock()
        transactionContextCounter += 1
        let contextID = transactionContextCounter
        activeTransactionContext = contextID
        defer {
            activeTransactionContext = nil
            unlock()
        }

        do {
            _ = try await runSimpleQuery("BEGIN")
        } catch {
            forceCloseIfDesynced(error)
            throw error
        }
        do {
            let result = try await body(Transaction(connection: self, contextID: contextID))
            // A cancel or timeout observed after the body finished but before COMMIT must roll back,
            // not commit: checking here turns that window into a ROLLBACK (via the catch below)
            // rather than a silent commit. Once COMMIT reaches the wire its outcome is indeterminate
            // — it runs uncancellable to completion, so a cancel racing it may still commit.
            try Task.checkCancellation()
            _ = try await runSimpleQuery("COMMIT")
            return result
        } catch {
            // A desynced wire can't carry a ROLLBACK: reading its bogus reply could hang on a
            // garbage length. Tear the connection down instead (the server rolls the aborted
            // transaction back on disconnect). Otherwise the wire is in sync — roll back, and
            // tear down only if the ROLLBACK itself desyncs.
            if let perun = error as? PerunError, perun.mayHaveDesynchronizedWire {
                forceCloseIfDesynced(error)
            } else {
                do { _ = try await runSimpleQuery("ROLLBACK") }
                catch let rollbackError { forceCloseIfDesynced(rollbackError) }
            }
            throw error
        }
    }

    private func validateTransactionContext(_ contextID: Int) throws {
        guard activeTransactionContext == contextID else {
            throw PerunError.protocolViolation("transaction context is no longer active")
        }
    }

    private var inlineReadGeneration: UInt64 = 0

    /// Run one inline (exclusive-path) request/response as a cancellable operation — the
    /// `runReadOp` treatment for a transaction-body query, which reads inline instead of
    /// through the background reader. A cancel fires a `CancelRequest`
    /// (`cancelInlineInFlight`) so the blocked inline read unblocks; the response still
    /// drains to `ReadyForQuery` (the wire stays in sync), and the outcome is reported as
    /// `CancellationError`. The `generation` guard stops a late cancel from hitting a later
    /// inline op. Only the transaction *body* is wrapped — BEGIN/COMMIT/ROLLBACK run
    /// uncancellable, so a timed-out transaction still rolls back cleanly.
    /// - Parameter onCancelledAfterSuccess: run when `body` *succeeded* but the task was cancelled,
    ///   so its result is about to be discarded. For a plain query the wire is already back at
    ///   ReadyForQuery, so nothing is needed (the default). A COPY handshake, though, leaves the
    ///   server in copy mode on success — abandoning that would desynchronise the wire — so the
    ///   caller uses this to clean up (tear the connection down) rather than hand it back mid-COPY.
    private func runInlineCancellable<T: Sendable>(
        _ body: () async throws -> T,
        onCancelledAfterSuccess: () async -> Void = {}
    ) async throws -> T {
        inlineReadGeneration += 1
        let generation = inlineReadGeneration
        let outcome: Result<T, Error> = await withTaskCancellationHandler {
            do { return .success(try await body()) }
            catch { return .failure(error) }
        } onCancel: {
            Task { await self.cancelInlineInFlight(generation: generation) }
        }
        if Task.isCancelled {
            if case .success = outcome { await onCancelledAfterSuccess() }
            throw CancellationError()
        }
        return try outcome.get()
    }

    /// A task awaiting a transaction-body query was cancelled: under exclusive access the
    /// running query is this one, so ask the server to cancel it. Best-effort, like
    /// `cancelInFlightRead`; the response still drains and the caller sees `CancellationError`.
    private func cancelInlineInFlight(generation: UInt64) async {
        guard !isClosed, exclusiveHeld, inlineReadGeneration == generation else { return }
        try? await sendCancelRequest()
    }

    private func runTransactionSimpleQuery(_ sql: String, contextID: Int) async throws -> QueryResult {
        try validateTransactionContext(contextID)
        return try await runInlineCancellable { try await self.runSimpleQuery(sql) }
    }

    private func runTransactionParameterizedQuery(_ sql: String,
                                                  _ parameters: [(any PostgresEncodable)?],
                                                  parameterFormat: PostgresFormat,
                                                  resultFormat: PostgresFormat,
                                                  contextID: Int) async throws -> QueryResult {
        try validateTransactionContext(contextID)
        return try await runInlineCancellable {
            try await self.runParameterizedQuery(sql, parameters,
                                                 parameterFormat: parameterFormat,
                                                 resultFormat: resultFormat)
        }
    }

    private func runTransactionPrepare(_ sql: String, contextID: Int) async throws -> PreparedStatement {
        try validateTransactionContext(contextID)
        return try await runInlineCancellable { try await self.runPrepare(sql) }
    }

    private func runTransactionExecute(_ statement: PreparedStatement,
                                       _ parameters: [(any PostgresEncodable)?],
                                       parameterFormat: PostgresFormat,
                                       resultFormat: PostgresFormat,
                                       contextID: Int) async throws -> QueryResult {
        try validateTransactionContext(contextID)
        return try await runInlineCancellable {
            try await self.runExecute(statement, parameters,
                                      parameterFormat: parameterFormat,
                                      resultFormat: resultFormat)
        }
    }

    private func runTransactionClosePrepared(_ statement: PreparedStatement,
                                             contextID: Int) async throws {
        try validateTransactionContext(contextID)
        try await runInlineCancellable { try await self.runClosePrepared(statement) }
    }

    // MARK: - Notices, LISTEN/NOTIFY, cancellation

    /// Register a handler called for every `NoticeResponse` (warnings, and the
    /// like). Replaces any previous handler.
    public func onNotice(_ handler: @escaping @Sendable (PostgresServerError) -> Void) {
        noticeHandler = handler
    }

    /// Subscribe to a channel (`LISTEN`). Notifications arrive on `notifications`;
    /// drive delivery with `waitForNotifications()`.
    public func listen(to channel: String) async throws {
        try await query("LISTEN \(Self.quoteIdentifier(channel))")
    }

    /// Unsubscribe from a channel (`UNLISTEN`).
    public func unlisten(from channel: String) async throws {
        try await query("UNLISTEN \(Self.quoteIdentifier(channel))")
    }

    /// Dedicate this connection to reading notifications, yielding each to
    /// `notifications`, until the task is cancelled or the connection closes.
    /// Holds the wire exclusively for its whole duration (no query can pipeline while
    /// it listens), so run it on a connection you reserve for listening.
    ///
    /// The loop spends almost all its time parked in a blocking read, so cancellation can't
    /// be observed between messages the way a query's can. Cancelling therefore **closes the
    /// connection** to unblock the read (as `close()` does) and throws `CancellationError`;
    /// the connection is not reusable afterwards. Open a dedicated connection for listening.
    public func waitForNotifications() async throws {
        try await lock(); defer { unlock() }
        do {
            try await withTaskCancellationHandler {
                while true {
                    try Task.checkCancellation()
                    switch try await readMessage() {
                    case let .notificationResponse(processID, channel, payload):
                        notificationContinuation.yield(
                            PostgresNotification(processID: processID, channel: channel, payload: payload))
                    case let .noticeResponse(notice):
                        noticeHandler?(notice)
                    case let .parameterStatus(name, value):
                        parameters[name] = value
                    case let .errorResponse(error):
                        throw PerunError.server(error)
                    default:
                        continue
                    }
                }
            } onCancel: {
                // Parked in recv with nothing to make the server send a byte: close the socket
                // so the read returns instead of the loop (and its exclusive lock) hanging forever.
                Task { await self.forceClose() }
            }
        } catch {
            // The forceClose above surfaces as connectionClosed; report the cancellation instead.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// Ask the server to cancel whatever query is currently running on this
    /// connection. Best-effort: it opens a *separate* connection to deliver the
    /// request (so it works while this one is blocked mid-query) and may race the
    /// query finishing on its own.
    public func cancelCurrentQuery() async throws {
        try await sendCancelRequest()
    }

    private func sendCancelRequest() async throws {
        let processID = backendProcessID
        let secretKey = backendSecretKey
        guard processID != 0 else { return }
        let host = self.host
        let port = self.port
        // The cancel key was delivered confidentially inside TLS; if the session is encrypted,
        // secure the cancel connection too rather than re-exposing the key in cleartext.
        let useTLS = isSecure
        let verifyFull = tlsMode == .verifyFull
        // A dedicated queue and a *separate* socket: this connection may be parked in a
        // blocking recv waiting for the very query we're trying to cancel.
        let cancelQueue = DispatchQueue(label: "perun.cancel")
        let timeout = connectTimeout
        let start = ContinuousClock().now

        // The TCP connect is bounded by makeConnected's own poll deadline.
        let fd = try await withBlockingIO(on: cancelQueue) {
            try SystemSocket.makeConnected(host: host, port: port, timeout: timeout)
        }
        // Bound the rest — the SSL reply read, the TLS handshake, and the send — with the same
        // absolute deadline connect() uses: a partially-responding server must not pin this task
        // forever (the original query and any wrapping withTimeout would keep waiting on it). The
        // watchdog shuts the socket down when the deadline passes so a parked recv/handshake/send
        // returns. A nil connectTimeout means no bound, matching connect().
        let watchdog: Task<Void, Never>? = timeout.map { total in
            Task {
                let remaining = total - (ContinuousClock().now - start)
                let capped = min(max(remaining, .zero), .seconds(Int64(Int32.max)))
                do { try await Task.sleep(for: capped) } catch { return }   // cancelled: finished in time
                SystemSocket.shutdownBoth(fd: fd)
            }
        }
        func stopWatchdog() async {
            watchdog?.cancel()
            _ = await watchdog?.value   // let it finish touching fd before we close it
        }
        do {
            try await withBlockingIO(on: cancelQueue) {
                let request = FrontendMessage.cancelRequest(processID: processID, secretKey: secretKey)
                guard useTLS else {
                    try SystemSocket.sendAll(fd: fd, request)
                    return
                }
                // SSLRequest, then send the CancelRequest over TLS. If the server declines TLS here,
                // don't fall back to plaintext — skip the cancel rather than leak the key (it's
                // best-effort anyway).
                try SystemSocket.sendAll(fd: fd, FrontendMessage.sslRequest())
                let reply = try SystemSocket.receive(fd: fd, maxLength: 1)
                guard reply.first == UInt8(ascii: "S") else { return }
                let tls = try TLSConnection.connect(fd: fd, hostname: host, verifyFull: verifyFull)
                defer { tls.close() }
                try tls.send(request)
            }
        } catch {
            await stopWatchdog()
            SystemSocket.disconnect(fd: fd)
            throw error
        }
        await stopWatchdog()
        SystemSocket.disconnect(fd: fd)
    }

    /// Double-quote a SQL identifier, escaping embedded quotes.
    private static func quoteIdentifier(_ identifier: String) -> String {
        var quoted = "\""
        for character in identifier {
            quoted.append(character)
            if character == "\"" { quoted.append("\"") }
        }
        quoted.append("\"")
        return quoted
    }

    // MARK: - Request drivers and response readers
    //
    // The inline drivers (`runSimpleQuery`, `runParameterizedQuery`, `runPrepare`,
    // `runExecute`, `runClosePrepared`) send a request and read its reply inline; only the
    // transaction path uses them now, under exclusive access. The `runPipelined*` drivers
    // instead hand their request to `runReadOp`, so batches pipeline under shared access
    // like a plain query. The `collect*` / `readPrepareResult` readers are context-neutral:
    // they run inline for the exclusive paths and as the background reader's read closures
    // for the shared, pipelined ones, so they assume neither exclusive access nor the
    // caller's task.

    private func runSimpleQuery(_ sql: String) async throws -> QueryResult {
        try await send(FrontendMessage.query(sql))
        return try await collectResults()
    }

    private func runParameterizedQuery(_ sql: String,
                                       _ parameters: [(any PostgresEncodable)?],
                                       parameterFormat: PostgresFormat,
                                       resultFormat: PostgresFormat) async throws -> QueryResult {
        // With no parameters and text results, the Simple Query protocol is
        // lighter (a single round trip). Binary still needs the extended path.
        guard !(parameters.isEmpty && resultFormat == .text) else {
            return try await runSimpleQuery(sql)
        }

        try await send(try FrontendMessage.parameterizedQuery(query: sql,
                                                              parameters: parameters,
                                                              parameterFormat: parameterFormat,
                                                              resultFormat: resultFormat))

        return try await collectResults()
    }

    private func nextStatementName() -> String {
        preparedStatementCounter += 1
        return "perun_stmt_\(String(connectionID, radix: 16))_\(preparedStatementCounter)"
    }

    private func runPrepare(_ sql: String) async throws -> PreparedStatement {
        let name = nextStatementName()
        try await send(try FrontendMessage.prepare(statement: name, query: sql))
        return try await readPrepareResult(name: name)
    }

    /// Read a `Parse`/`Describe` reply: parameter and row descriptions up to `ReadyForQuery`.
    private func readPrepareResult(name: String) async throws -> PreparedStatement {
        var parameterTypeOIDs: [Int32] = []
        var columns: [ColumnMetadata] = []
        var pendingError: PostgresServerError?

        loop: while true {
            switch try await readMessage() {
            case let .parameterDescription(oids):
                parameterTypeOIDs = oids
            case let .rowDescription(fields):
                columns = fields.map(ColumnMetadata.init)
            case .noData:
                columns = []
            case let .parameterStatus(name, value):
                parameters[name] = value
            case let .noticeResponse(notice):
                noticeHandler?(notice)
            case let .notificationResponse(processID, channel, payload):
                notificationContinuation.yield(
                    PostgresNotification(processID: processID, channel: channel, payload: payload))
            case .parseComplete:
                continue
            case let .errorResponse(error):
                pendingError = error
            case let .readyForQuery(status):
                transactionStatus = status
                break loop
            default:
                continue
            }
        }

        if let pendingError {
            throw PerunError.server(pendingError)
        }
        return PreparedStatement(name: name,
                                 parameterTypeOIDs: parameterTypeOIDs,
                                 columns: columns,
                                 connectionID: connectionID)
    }

    private func runExecute(_ statement: PreparedStatement,
                            _ parameters: [(any PostgresEncodable)?],
                            parameterFormat: PostgresFormat,
                            resultFormat: PostgresFormat) async throws -> QueryResult {
        try validatePreparedStatement(statement)
        try validateBinaryParameterTypes(statement, parameters, parameterFormat: parameterFormat)
        try await send(try FrontendMessage.execute(statement: statement.name,
                                                   parameters: parameters,
                                                   parameterFormat: parameterFormat,
                                                   resultFormat: resultFormat))
        // Execute alone sends no RowDescription; reuse the prepared statement's columns.
        return try await collectResults(initialColumns: preparedResultColumns(statement, resultFormat: resultFormat))
    }

    private func runClosePrepared(_ statement: PreparedStatement) async throws {
        try validatePreparedStatement(statement)
        try await send(FrontendMessage.closeAndSync(.statement, name: statement.name))
        _ = try await collectResults()
    }

    /// Atomic pipeline: send every `Bind`/`Execute` under one trailing `Sync`, then
    /// read one result set per `CommandComplete` up to the single `ReadyForQuery`.
    private func runPipelinedExecute(_ statement: PreparedStatement,
                                     _ parameterSets: [[(any PostgresEncodable)?]],
                                     parameterFormat: PostgresFormat,
                                     resultFormat: PostgresFormat,
                                     syncAfterEach: Bool) async throws -> [QueryResult] {
        let request = try FrontendMessage.pipelinedExecute(statement: statement.name,
                                                           parameterSets: parameterSets,
                                                           parameterFormat: parameterFormat,
                                                           resultFormat: resultFormat,
                                                           syncAfterEach: syncAfterEach)
        let columns = preparedResultColumns(statement, resultFormat: resultFormat)
        return try await runReadOp(sending: request) {
            try await self.collectPipelinedResults(defaultColumns: columns)
        }
    }

    /// Independent pipeline: a `Sync` after each set, so results and errors are
    /// per-set. Reuses the single-result reader once per set — each `ReadyForQuery`
    /// bounds one set, and a server error there leaves the wire in sync for the next.
    private func runPipelinedExecuteIndependently(_ statement: PreparedStatement,
                                                  _ parameterSets: [[(any PostgresEncodable)?]],
                                                  parameterFormat: PostgresFormat,
                                                  resultFormat: PostgresFormat) async throws -> [Result<QueryResult, Error>] {
        let request = try FrontendMessage.pipelinedExecute(statement: statement.name,
                                                           parameterSets: parameterSets,
                                                           parameterFormat: parameterFormat,
                                                           resultFormat: resultFormat,
                                                           syncAfterEach: true)
        let columns = preparedResultColumns(statement, resultFormat: resultFormat)
        let count = parameterSets.count
        return try await runReadOp(sending: request) {
            try await self.collectIndependentResults(count: count, defaultColumns: columns)
        }
    }

    /// Reader for a `Sync`-per-command pipeline: run the single-result reader once per
    /// command, wrapping each outcome in a `Result`. A server/local error there leaves
    /// the wire in sync for the next command; a wire-desync error propagates and aborts.
    private func collectIndependentResults(count: Int,
                                           defaultColumns: [ColumnMetadata]) async throws -> [Result<QueryResult, Error>] {
        var results: [Result<QueryResult, Error>] = []
        results.reserveCapacity(count)
        for _ in 0 ..< count {
            do {
                results.append(.success(try await collectResults(initialColumns: defaultColumns)))
            } catch let error as PerunError where !error.mayHaveDesynchronizedWire {
                results.append(.failure(error))
            }
        }
        return results
    }

    /// Atomic heterogeneous pipeline: `Parse`/`Bind`/`Describe`/`Execute` per query
    /// under one trailing `Sync`. Each query describes itself, so the reader starts
    /// each result set with no columns.
    private func runPipelinedQueries(_ queries: [PostgresQuery], syncAfterEach: Bool) async throws -> [QueryResult] {
        let request = try FrontendMessage.pipelinedQueries(queries, syncAfterEach: syncAfterEach)
        return try await runReadOp(sending: request) {
            try await self.collectPipelinedResults(defaultColumns: [])
        }
    }

    private func runPipelinedQueriesIndependently(_ queries: [PostgresQuery]) async throws -> [Result<QueryResult, Error>] {
        let request = try FrontendMessage.pipelinedQueries(queries, syncAfterEach: true)
        let count = queries.count
        return try await runReadOp(sending: request) {
            try await self.collectIndependentResults(count: count, defaultColumns: [])
        }
    }

    /// A prepared statement is described in text; re-tag its columns as binary when
    /// binary results were requested (its own `Execute` sends no RowDescription).
    private func preparedResultColumns(_ statement: PreparedStatement, resultFormat: PostgresFormat) -> [ColumnMetadata] {
        resultFormat == .binary ? statement.columns.map { $0.withFormatCode(1) } : statement.columns
    }

    /// Reader for a pipeline that ends in a single `Sync`: one `QueryResult` per
    /// `CommandComplete`, all bounded by the final `ReadyForQuery`. The batch is one
    /// implicit transaction, so any error rolled the whole thing back — we throw and
    /// drop the partial results rather than return them.
    private func collectPipelinedResults(defaultColumns: [ColumnMetadata]) async throws -> [QueryResult] {
        var results: [QueryResult] = []
        var columns = defaultColumns
        var rowValues: [[[UInt8]?]] = []
        var pendingError: PostgresServerError?

        loop: while true {
            switch try await readMessage() {
            case let .rowDescription(fields):
                columns = fields.map(ColumnMetadata.init)
                rowValues.removeAll(keepingCapacity: true)

            case let .dataRow(values):
                guard values.count == columns.count else {
                    throw PerunError.protocolViolation(
                        "DataRow has \(values.count) values but the row has \(columns.count) columns")
                }
                rowValues.append(values)

            case let .commandComplete(tag):
                results.append(QueryResult(columns: columns, values: rowValues, commandTag: tag))
                columns = defaultColumns
                rowValues = []

            case .emptyQueryResponse:
                results.append(QueryResult(columns: defaultColumns, values: [], commandTag: ""))
                columns = defaultColumns
                rowValues = []

            case .copyInResponse, .copyOutResponse:
                // COPY has no place in a pipeline (it needs a writer/reader), and neither
                // direction can be recovered in band here (see collectResults): tear the
                // connection down.
                forceClose()
                throw PerunError.copyMismatch("COPY is not supported inside a pipeline")

            case let .parameterStatus(name, value):
                parameters[name] = value

            case let .noticeResponse(notice):
                noticeHandler?(notice)

            case let .notificationResponse(processID, channel, payload):
                notificationContinuation.yield(
                    PostgresNotification(processID: processID, channel: channel, payload: payload))

            case .parseComplete, .bindComplete, .closeComplete,
                 .noData, .parameterDescription, .portalSuspended:
                continue

            case let .errorResponse(error):
                pendingError = error

            case let .readyForQuery(status):
                transactionStatus = status
                break loop

            default:
                continue
            }
        }

        if let pendingError {
            throw PerunError.server(pendingError)
        }
        return results
    }

    private func validatePreparedStatement(_ statement: PreparedStatement) throws {
        guard statement.connectionID == connectionID else {
            throw PerunError.preparedStatementConnectionMismatch
        }
    }

    /// `Bind` carries no parameter type OIDs, so a binary parameter is decoded by the server as
    /// the type it inferred for that placeholder at `Parse` time. Reject a value whose wire type
    /// differs (e.g. a `Double` bound to a `bigint` parameter), which the server would otherwise
    /// silently reinterpret whenever the widths happen to match. Only binary values are checked —
    /// a text fallback is parsed type-agnostically, and a placeholder the server left untyped
    /// (OID 0) accepts anything.
    private func validateBinaryParameterTypes(_ statement: PreparedStatement,
                                              _ parameters: [(any PostgresEncodable)?],
                                              parameterFormat: PostgresFormat) throws {
        guard parameterFormat == .binary else { return }
        for (index, parameter) in parameters.enumerated() {
            guard let parameter, index < statement.parameterTypeOIDs.count else { continue }
            let expected = statement.parameterTypeOIDs[index]
            guard expected != 0, parameter.postgresBinary() != nil else { continue }
            guard parameter.postgresTypeOID == expected else {
                throw PerunError.parameterTypeMismatch(parameter: index + 1,
                                                       expected: expected,
                                                       actual: parameter.postgresTypeOID)
            }
        }
    }

    // MARK: - Background response reader

    /// One outstanding request whose response the reader will deliver. A reference type,
    /// so an in-flight cancellation can check it is still the sole request before asking
    /// the server to cancel. `run` reads the response with the operation's own reader,
    /// resumes the caller, and reports whether the wire is still in sync; `fail` resumes
    /// the caller during teardown.
    private final class PendingRead: @unchecked Sendable {
        var run: () async -> Bool = { true }
        var fail: (Error) -> Void = { _ in }
    }

    private var pendingReads: [PendingRead] = []
    private var currentRead: PendingRead?               // the read the reader is running now (popped)
    private var readerStarted = false

    /// Send a request and let the background reader deliver its response: enqueue the
    /// read (in order), write the request, and await the result. Responses are matched
    /// to requests by wire order — v3 has no request IDs, so order is the correlation.
    private func runReadOp<T>(sending request: [UInt8],
                              read: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !isClosed else { throw PerunError.connectionClosed }
        try Task.checkCancellation()                     // cancelled before we send → don't send
        startReaderIfNeeded()
        let op = PendingRead()
        let outcome: Result<T, Error> = await withTaskCancellationHandler {
            do {
                return .success(try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                    op.run = {
                        do {
                            continuation.resume(returning: try await read())
                            return true
                        } catch {
                            continuation.resume(throwing: error)
                            if let perun = error as? PerunError, perun.mayHaveDesynchronizedWire { return false }
                            return true                  // server/local error: wire still in sync
                        }
                    }
                    op.fail = { continuation.resume(throwing: $0) }
                    pendingReads.append(op)
                    if isClosed {                        // close raced in after the guard
                        failAllPendingReads(PerunError.connectionClosed)
                        return
                    }
                    kickWrite(request)
                    // Defensive: this runs synchronously on the actor after the earlier
                    // startReaderIfNeeded(), so the reader can't have drained and exited in
                    // between — but re-arm it here too, so enqueueing an op never depends on
                    // that ordering to guarantee a reader is running to deliver its response.
                    startReaderIfNeeded()
                })
            } catch {
                return .failure(error)
            }
        } onCancel: {
            Task { await self.cancelInFlightRead(op) }
        }
        // The response drained through the reader. Honor cancellation over its outcome.
        if Task.isCancelled { throw CancellationError() }
        return try outcome.get()
    }

    /// A task awaiting an in-flight query was cancelled: if the server is running *this*
    /// query right now (it is the read the reader is currently draining), ask it to
    /// cancel. `CancelRequest` is per-backend — it cancels whatever is running — so we
    /// only fire it when the running query is this one; a still-queued cancelled query
    /// would cancel someone else's, so we let it finish instead. Either way the response
    /// drains and `runReadOp` reports `CancellationError`.
    ///
    /// Best-effort, as `CancelRequest` is: it races the query. The query may already have
    /// committed (or not yet reached the server, since the write is dispatched
    /// asynchronously), so `CancellationError` does not prove it didn't run.
    private func cancelInFlightRead(_ op: PendingRead) async {
        guard !isClosed, currentRead === op else { return }
        try? await sendCancelRequest()
    }

    private func startReaderIfNeeded() {
        guard !readerStarted, !isClosed else { return }
        readerStarted = true
        // The reader exits when the queue drains (see readerLoop), so `[weak self]` lets a
        // connection dropped without close() deallocate instead of being pinned forever; we
        // restart on demand from here when the next request arrives.
        Task { [weak self] in await self?.readerLoop() }
    }

    /// Deliver responses in FIFO order. Pops each read *before* running it, so teardown can
    /// never double-resume the one in flight. A wire-desync error tears the connection down and
    /// fails everything still queued. The loop exits once the queue drains rather than parking:
    /// a parked continuation stored on the actor would retain it forever, so a connection dropped
    /// without close() could never be reclaimed. `startReaderIfNeeded` restarts it on the next
    /// request.
    private func readerLoop() async {
        while !isClosed, !pendingReads.isEmpty {
            let op = pendingReads.removeFirst()
            currentRead = op                             // the request the backend is running now
            let inSync = await op.run()
            currentRead = nil
            if inSync == false {
                forceClose()
                break
            }
        }
        readerStarted = false                            // idle or closed: a later request restarts us
        if isClosed { failAllPendingReads(PerunError.connectionClosed) }
    }

    private func failAllPendingReads(_ error: Error) {
        let ops = pendingReads
        pendingReads.removeAll()
        for op in ops { op.fail(error) }
    }

    /// Write a request without awaiting completion, preserving enqueue order. A write
    /// failure is fatal to the wire, so it tears the connection down.
    private func kickWrite(_ bytes: [UInt8]) {
        guard !isClosed else { return }
        let fd = self.fd
        let tls = self.tls
        ioQueue.async {
            do {
                if let tls { try tls.send(bytes) } else { try SystemSocket.sendAll(fd: fd, bytes) }
            } catch {
                Task { await self.forceClose() }
            }
        }
    }

    // MARK: - Shared / exclusive wire access
    //
    // Single-request calls — `query`, `prepare`, `execute`, `closePrepared` and pipelined
    // batches (a batch is one contiguous request) — take SHARED access: they pipeline
    // through the background reader, so several can be in flight at once. The multi-request
    // and long-lived inline readers — transactions and `waitForNotifications` — take
    // EXCLUSIVE access (`lock`), which drains the in-flight shared queries and blocks new
    // ones, so it owns the wire while the reader sits idle. A readers-writer lock with
    // writer priority; both waiter kinds are cancellation-aware.

    private var exclusiveHeld = false
    private var inFlightShared = 0
    private var exclusiveWaiters: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    private var sharedWaiters: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextAccessWaiterID: UInt64 = 0

    /// Take shared access for a pipelined query. Blocks while an exclusive holder is
    /// active or waiting (writer priority, so exclusive access can't starve).
    private func acquireShared() async throws {
        // A force-closed connection freezes the lock state (a stream/COPY torn down by a wire
        // error never unlocks), so refuse up front rather than park a waiter nothing will resume.
        guard !isClosed else { throw PerunError.connectionClosed }
        if !exclusiveHeld && exclusiveWaiters.isEmpty {
            inFlightShared += 1
            return
        }
        let id = nextAccessWaiterID
        nextAccessWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sharedWaiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelSharedWaiter(id) }
        }
        // Granted: the waker already counted us in `inFlightShared`. If cancellation won
        // the hand-off, give the slot back and fail.
        if Task.isCancelled {
            releaseShared()
            throw CancellationError()
        }
    }

    private func releaseShared() {
        inFlightShared -= 1
        if inFlightShared == 0 { grantExclusiveIfReady() }
    }

    private func cancelSharedWaiter(_ id: UInt64) {
        guard let index = sharedWaiters.firstIndex(where: { $0.id == id }) else { return }
        sharedWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Take exclusive use of the wire, after draining any in-flight shared queries.
    /// Suspends (FIFO) while shared queries drain or another exclusive holder is active.
    /// Throws `CancellationError` if cancelled before it acquires — a parked waiter
    /// never touched the wire.
    private func lock() async throws {
        guard !isClosed else { throw PerunError.connectionClosed }   // see acquireShared: never park on a dead wire
        if !exclusiveHeld && inFlightShared == 0 {
            exclusiveHeld = true
            return
        }
        let id = nextAccessWaiterID
        nextAccessWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    exclusiveWaiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelExclusiveWaiter(id) }
        }
        // Handed the wire by a release. If cancellation won the hand-off, pass it on.
        if Task.isCancelled {
            unlock()
            throw CancellationError()
        }
    }

    /// Release exclusive access: hand to the next exclusive waiter, else wake all shared.
    private func unlock() {
        exclusiveHeld = false
        if !exclusiveWaiters.isEmpty {
            grantExclusiveIfReady()
        } else {
            grantAllShared()
        }
    }

    private func cancelExclusiveWaiter(_ id: UInt64) {
        guard let index = exclusiveWaiters.firstIndex(where: { $0.id == id }) else { return }
        exclusiveWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        // Removing the last exclusive waiter lifts writer priority — parked shared may go.
        if exclusiveWaiters.isEmpty && !exclusiveHeld { grantAllShared() }
    }

    /// Grant exclusive to the head waiter once the wire is free and shared has drained.
    private func grantExclusiveIfReady() {
        guard !exclusiveHeld, inFlightShared == 0, !exclusiveWaiters.isEmpty else { return }
        exclusiveHeld = true
        exclusiveWaiters.removeFirst().continuation.resume()
    }

    /// Wake every parked shared query — they pipeline together.
    private func grantAllShared() {
        guard !exclusiveHeld, exclusiveWaiters.isEmpty else { return }
        let waiters = sharedWaiters
        sharedWaiters.removeAll()
        for waiter in waiters {
            inFlightShared += 1
            waiter.continuation.resume()
        }
    }

    /// Fail every task parked for wire access (on teardown).
    private func failAllAccessWaiters(_ error: Error) {
        let shared = sharedWaiters
        let exclusive = exclusiveWaiters
        sharedWaiters.removeAll()
        exclusiveWaiters.removeAll()
        for waiter in shared { waiter.continuation.resume(throwing: error) }
        for waiter in exclusive { waiter.continuation.resume(throwing: error) }
    }

    /// Drive the read loop until `ReadyForQuery`, assembling a `QueryResult`.
    /// Shared by the simple and extended query paths.
    private func collectResults(initialColumns: [ColumnMetadata] = []) async throws -> QueryResult {
        var columns = initialColumns
        var rowValues: [[[UInt8]?]] = []
        // The most recently completed statement's result. A simple query may run several
        // statements; snapshotting at each CommandComplete keeps a statement's rows and command
        // tag together, so a trailing no-rows statement can't pair its tag with an earlier
        // statement's rows.
        var resultColumns = initialColumns
        var resultRows: [[[UInt8]?]] = []
        var resultTag = ""
        var pendingError: PostgresServerError?

        loop: while true {
            let message = try await readMessage()
            switch message {
            case let .rowDescription(fields):
                columns = fields.map(ColumnMetadata.init)
                rowValues.removeAll(keepingCapacity: true)

            case let .dataRow(values):
                guard values.count == columns.count else {
                    throw PerunError.protocolViolation(
                        "DataRow has \(values.count) values but the row has \(columns.count) columns")
                }
                rowValues.append(values)

            case let .commandComplete(tag):
                resultColumns = columns
                resultRows = rowValues
                resultTag = tag
                columns = initialColumns          // reset for the next statement in the batch
                rowValues = []

            case .emptyQueryResponse:
                resultColumns = initialColumns
                resultRows = []
                resultTag = ""
                columns = initialColumns
                rowValues = []

            case .copyInResponse:
                // A `COPY … FROM STDIN` was issued through query()/execute(): the server now waits
                // for CopyData these paths never send. Aborting with CopyFail resynchronises a
                // Simple Query, but not the extended protocol — its pre-sent Sync is ignored during
                // COPY, and after CopyFail the server waits for a *fresh* Sync that never comes — so
                // tear the connection down uniformly. This is an API misuse; use copyIn(_:_:).
                forceClose()
                throw PerunError.copyMismatch(
                    "COPY … FROM STDIN must be run with copyIn(_:_:), not query()/execute()")

            case .copyOutResponse:
                // A `COPY … TO STDOUT` was issued through query()/execute(): the server streams
                // the result to us. A COPY-out can't be stopped in band; the stream can be huge or
                // unbounded, so draining it just to reuse the connection is costly, and an
                // out-of-band CancelRequest races the next query on the reused connection. So tear
                // the connection down — this is an API misuse, so discarding it is acceptable.
                forceClose()
                throw PerunError.copyMismatch(
                    "COPY … TO STDOUT must be run with copyOut(_:), not query()/execute()")

            case let .parameterStatus(name, value):
                parameters[name] = value

            case let .noticeResponse(notice):
                noticeHandler?(notice)

            case let .notificationResponse(processID, channel, payload):
                notificationContinuation.yield(
                    PostgresNotification(processID: processID, channel: channel, payload: payload))

            case .parseComplete, .bindComplete, .closeComplete,
                 .noData, .parameterDescription, .portalSuspended:
                continue                // acknowledgements we don't need to act on

            case let .errorResponse(error):
                // Remember it, but keep reading: the server still sends
                // ReadyForQuery, and we must consume it to stay in sync.
                pendingError = error

            case let .readyForQuery(status):
                transactionStatus = status
                break loop

            default:
                continue
            }
        }

        if let pendingError {
            throw PerunError.server(pendingError)
        }
        return QueryResult(columns: resultColumns, values: resultRows, commandTag: resultTag)
    }

    // MARK: - Row streaming
    //
    // A stream holds the wire exclusively (like a transaction) and reads inline, one
    // portal chunk at a time: `Execute(maxRows)` + `Flush` per chunk, keeping the named
    // portal open across chunks (no `Sync`) until it is exhausted or the consumer stops.
    // `nextStreamRow` is the consumer's pull; `finishStream` is the abandon path called
    // from the stream's `deinit`.

    private var streamActive = false
    private var streamPortal = ""
    private var streamChunkSize: Int32 = 0
    private var streamColumns: [ColumnMetadata] = []
    private var streamColumnIndex: [String: Int] = [:]
    private var streamTerminating = false            // terminating Sync sent; draining to ReadyForQuery
    private var streamPendingError: PostgresServerError?
    private var streamPortalCounter = 0
    private var streamGeneration: UInt64 = 0          // identifies the current stream for cancellation

    /// The consumer pulled the next row. Cancellation-aware: if the consuming task is
    /// cancelled while we wait for the server (e.g. mid `pg_sleep`), fire a `CancelRequest`
    /// so the read unblocks — exactly as an autocommit query does — then tear the stream
    /// down and throw `CancellationError`, so a cancelled `for await` frees the connection
    /// promptly instead of blocking until the next backend message arrives.
    func nextStreamRow(generation: UInt64) async throws -> PostgresRow? {
        // Only the stream this iterator was created for may pull rows. A stale iterator — its
        // stream already ended, and the connection may have started a new one — reads nothing
        // rather than silently returning a different stream's rows. The cancellation cleanup
        // below uses that same captured generation, so a cancelled stale iterator can't tear
        // down whatever stream is active now.
        guard streamActive, streamGeneration == generation else { return nil }
        if Task.isCancelled {
            // Already cancelled before we read a byte: abort the running query too, so a
            // slow one (e.g. mid `pg_sleep`) doesn't stall the drain inside finishStream.
            await cancelStreamInFlight(generation: generation)
            await finishStream(generation: generation)
            throw CancellationError()
        }
        let outcome: Result<PostgresRow?, Error> = await withTaskCancellationHandler {
            do { return .success(try await readNextStreamRow()) }
            catch { return .failure(error) }
        } onCancel: {
            Task { await self.cancelStreamInFlight(generation: generation) }
        }
        if Task.isCancelled {
            await finishStream(generation: generation)   // idempotent; cleans up if a row raced the cancel
            throw CancellationError()
        }
        return try outcome.get()
    }

    /// Read the wire until one DataRow (return it), the end (ReadyForQuery → nil), or an
    /// error, assuming an active stream. Chunk boundaries are crossed transparently: a
    /// PortalSuspended asks for the next chunk; a CommandComplete closes the portal.
    private func readNextStreamRow() async throws -> PostgresRow? {
        do {
            while true {
                let message = try await readMessage()
                switch message {
                case let .dataRow(values) where !streamTerminating:
                    guard values.count == streamColumns.count else {
                        throw PerunError.protocolViolation(
                            "DataRow has \(values.count) values but the row has \(streamColumns.count) columns")
                    }
                    return PostgresRow(values: values, columns: streamColumns, columnIndexByName: streamColumnIndex)

                case .copyInResponse, .copyOutResponse:
                    // queryStream isn't for COPY: FROM STDIN would wait for client data forever and
                    // TO STDOUT would silently stream the whole (possibly unbounded) relation. Tear
                    // the connection down (the catch below frees the wire and discards it).
                    throw PerunError.copyMismatch(
                        "COPY is not supported by queryStream; use copyIn(_:_:) or copyOut(_:)")

                case let .rowDescription(fields):
                    streamColumns = fields.map(ColumnMetadata.init)
                    streamColumnIndex = PostgresRow.makeColumnIndexByName(streamColumns)

                case .portalSuspended where !streamTerminating:
                    // Chunk boundary: request the next chunk and keep reading.
                    try await send(FrontendMessage.execute(portal: streamPortal, maxRows: streamChunkSize)
                                   + FrontendMessage.flush())

                case .commandComplete, .emptyQueryResponse:
                    // Portal exhausted: close it and end the implicit transaction.
                    if !streamTerminating {
                        streamTerminating = true
                        try await send(FrontendMessage.close(.portal, name: streamPortal) + FrontendMessage.sync())
                    }

                case let .errorResponse(error):
                    if streamPendingError == nil { streamPendingError = error }
                    if !streamTerminating {          // leave the error state and get ReadyForQuery
                        streamTerminating = true
                        try await send(FrontendMessage.sync())
                    }

                case let .parameterStatus(name, value):
                    parameters[name] = value

                case let .noticeResponse(notice):
                    noticeHandler?(notice)

                case let .notificationResponse(processID, channel, payload):
                    notificationContinuation.yield(
                        PostgresNotification(processID: processID, channel: channel, payload: payload))

                case let .readyForQuery(status):
                    transactionStatus = status
                    let error = streamPendingError
                    endStream()
                    if let error { throw PerunError.server(error) }
                    return nil

                default:
                    continue                          // a DataRow while draining, and acknowledgements
                }
            }
        } catch {
            // A clean server error already ran endStream (the wire is still in sync);
            // anything else is a wire/IO failure mid-stream, so tear the connection down.
            if streamActive {
                if !isClosed { forceClose() }
                streamActive = false
            }
            throw error
        }
    }

    /// The consumer abandoned the stream (its `deinit`). If it is still open, close the
    /// portal, drain the current chunk to ReadyForQuery, and free the wire. Idempotent — a
    /// stream consumed to its end already finished, so this is a no-op. The `generation` guard
    /// makes a late `deinit` a no-op once *this* stream has ended, so a stale cleanup can never
    /// tear down a newer stream that has since reused the connection.
    func finishStream(generation: UInt64) async {
        guard streamActive, streamGeneration == generation else { return }
        do {
            if !streamTerminating {
                streamTerminating = true
                try await send(FrontendMessage.close(.portal, name: streamPortal) + FrontendMessage.sync())
            }
            while streamActive {
                switch try await readMessage() {
                case let .readyForQuery(status):
                    transactionStatus = status
                    endStream()
                case let .parameterStatus(name, value):
                    parameters[name] = value
                case let .noticeResponse(notice):
                    noticeHandler?(notice)
                case let .notificationResponse(processID, channel, payload):
                    notificationContinuation.yield(
                        PostgresNotification(processID: processID, channel: channel, payload: payload))
                default:
                    continue                          // discard the remaining rows / acknowledgements
                }
            }
        } catch {
            if !isClosed { forceClose() }
            streamActive = false
        }
    }

    /// Finish a stream whose wire is still in sync: reset its state and release the
    /// exclusive hold.
    private func endStream() {
        guard streamActive else { return }
        streamActive = false
        streamTerminating = false
        streamColumns = []
        streamColumnIndex = [:]
        streamPendingError = nil
        streamPortal = ""
        unlock()
    }

    /// A streaming consumer was cancelled while awaiting a row: ask the server to cancel the
    /// running query so the read unblocks. Best-effort, like `cancelInFlightRead`. The
    /// `generation` guard makes a late cancel a no-op if that stream already ended (and a new
    /// one may hold the wire) — the stream owns the wire exclusively, so we never cancel a
    /// query that isn't the one this stream started.
    private func cancelStreamInFlight(generation: UInt64) async {
        guard !isClosed, streamActive, streamGeneration == generation else { return }
        try? await sendCancelRequest()
    }

    // MARK: - COPY OUT (server → client)
    //
    // A `COPY … TO STDOUT` streams `CopyData` under exclusive access, read inline like a
    // stream — but with no chunk requests: the server sends CopyData until CopyDone, then
    // CommandComplete and ReadyForQuery (Simple Query, so no Sync). A consumer that *breaks* out
    // drains the remainder (bounded, keep-if-cheap); a consumer that is *cancelled* shuts the socket
    // and discards the connection — no `CancelRequest`, which is async and could hit the next query.

    private var copyOutActive = false
    private var copyOutTerminating = false
    private var copyOutPendingError: PostgresServerError?
    private var copyOutGeneration: UInt64 = 0

    /// Holds the in-flight copyOut teardown Task so the pool's `release()` can await it settling
    /// (kept vs. discarded) instead of racing the bounded drain: release()'s local actor hop otherwise
    /// beats the network drain and discards a connection a cheap-remainder drain would have kept.
    /// Lock-guarded — written from the iterator's `deinit` (any thread), cleared on the actor when a
    /// new copyOut starts, read by `release()`.
    private let copyOutTeardownBox = TeardownBox()

    /// Record the teardown Task the iterator's `deinit` just spawned, so a concurrent `release()` can
    /// await it. Nonisolated and lock-guarded: the deinit runs synchronously at the `break` — before
    /// `withConnection` returns and calls `release()` — so the handle is always in place in time. The
    /// `generation` guard drops a stale iterator's late write, so it can't clobber a newer copy's task.
    nonisolated func recordCopyOutTeardown(generation: UInt64, task: Task<Void, Never>) {
        copyOutTeardownBox.record(generation: generation, task: task)
    }

    /// The row-stream analogue of `copyOutTeardownBox`: a broken `queryStream` drains in a detached
    /// `Task` too, so the pool must await it the same way before judging the connection.
    private let streamTeardownBox = TeardownBox()

    /// Record a stream teardown Task from the iterator's `deinit`, like `recordCopyOutTeardown`.
    nonisolated func recordStreamTeardown(generation: UInt64, task: Task<Void, Never>) {
        streamTeardownBox.record(generation: generation, task: task)
    }

    /// The in-flight teardown tasks the caller must await before sampling wire state (an abandoned
    /// copyOut or row stream tears down in a detached `Task`). Synchronous and nonisolated so a
    /// pool `release()`/`close()` pays no actor hop on the common path where nothing is tearing down
    /// (empty array → the caller's `for … await` loop suspends zero times).
    nonisolated func inFlightTeardownTasks() -> [Task<Void, Never>] {
        [copyOutTeardownBox.currentTask(), streamTeardownBox.currentTask()].compactMap { $0 }
    }

    /// How long a *break* out of a copyOut may spend draining the server's remaining stream to keep
    /// the connection reusable. A small remainder finishes well under this; a large or slow one hits
    /// it and the connection is closed+discarded instead. Task *cancellation* doesn't drain at all.
    /// Internal, not public config — it governs one rare abandonment path and can be promoted to
    /// configuration additively if real demand appears.
    private static let defaultCopyResyncTimeout: Duration = .seconds(5)
    private var copyResyncTimeout: Duration {
        #if DEBUG
        return copyResyncTimeoutOverride ?? Self.defaultCopyResyncTimeout
        #else
        return Self.defaultCopyResyncTimeout
        #endif
    }
    #if DEBUG
    private var copyResyncTimeoutOverride: Duration?
    func setCopyResyncTimeout(_ timeout: Duration) { copyResyncTimeoutOverride = timeout }
    /// Test seam: invoked in `nextCopyData` after the pre-read cancellation check but before the
    /// read, so a test can park there, cancel, and release — landing the cancel in the read window
    /// deterministically instead of racing `Task.sleep`.
    private var copyOutBeforeReadTestHook: (@Sendable () async -> Void)?
    func setCopyOutBeforeReadTestHook(_ hook: @escaping @Sendable () async -> Void) { copyOutBeforeReadTestHook = hook }
    #endif

    /// Consume the `CopyOutResponse` handshake after a `COPY … TO STDOUT` query. Drains to
    /// ReadyForQuery and throws if the statement errored or wasn't a COPY TO STDOUT.
    private func readCopyOutResponse() async throws {
        var pendingError: PostgresServerError?
        while true {
            switch try await readMessage() {
            case .copyOutResponse:
                return                           // the server will now stream CopyData
            case .copyInResponse:
                // Wrong direction: a COPY … FROM STDIN. The server is now waiting for client
                // data (so reading on would hang) — abort it with CopyFail, then surface it.
                try await failCopyIn()
                throw PerunError.copyMismatch("copyOut needs a COPY … TO STDOUT statement, not FROM STDIN")
            case let .errorResponse(error):
                pendingError = error             // e.g. bad SQL; drain to ReadyForQuery then throw
            case let .parameterStatus(name, value):
                parameters[name] = value
            case let .noticeResponse(notice):
                noticeHandler?(notice)
            case let .notificationResponse(processID, channel, payload):
                notificationContinuation.yield(
                    PostgresNotification(processID: processID, channel: channel, payload: payload))
            case let .readyForQuery(status):
                transactionStatus = status
                if let pendingError { throw PerunError.server(pendingError) }
                throw PerunError.copyMismatch("expected CopyOutResponse (is the statement a COPY … TO STDOUT?)")
            default:
                continue
            }
        }
    }

    /// The consumer pulled the next COPY chunk. Cancellation-aware like `nextStreamRow`.
    func nextCopyData(generation: UInt64) async throws -> [UInt8]? {
        // Guard on the iterator's own generation (see nextStreamRow): a stale copy iterator
        // reads nothing and can't tear down a copy that has since reused the connection.
        guard copyOutActive, copyOutGeneration == generation else { return nil }
        if Task.isCancelled {
            abandonCopyOutOnCancellation(generation: generation)   // discard promptly — no drain, no cancel
            throw CancellationError()
        }
        #if DEBUG
        await copyOutBeforeReadTestHook?()   // no-op unless a test installed a seam
        #endif
        let outcome: Result<[UInt8]?, Error> = await withTaskCancellationHandler {
            do { return .success(try await readNextCopyData()) }
            catch { return .failure(error) }
        } onCancel: {
            // Interrupt the parked read by tearing the connection down — forceClose's shutdown wakes
            // the recv. Hop to the actor and guard on generation; never shut an fd from onCancel raw.
            Task { await self.abandonCopyOutOnCancellation(generation: generation) }
        }
        if Task.isCancelled {
            abandonCopyOutOnCancellation(generation: generation)   // idempotent if a chunk raced the cancel
            throw CancellationError()
        }
        return try outcome.get()
    }

    /// Read the wire until one `CopyData` (return it) or the end (ReadyForQuery → nil),
    /// assuming an active copy.
    private func readNextCopyData() async throws -> [UInt8]? {
        do {
            while true {
                switch try await readMessage() {
                case let .copyData(bytes) where !copyOutTerminating:
                    return bytes

                case let .errorResponse(error):
                    if copyOutPendingError == nil { copyOutPendingError = error }
                    copyOutTerminating = true    // ignore any trailing CopyData; drain to ReadyForQuery

                case let .parameterStatus(name, value):
                    parameters[name] = value

                case let .noticeResponse(notice):
                    noticeHandler?(notice)

                case let .notificationResponse(processID, channel, payload):
                    notificationContinuation.yield(
                        PostgresNotification(processID: processID, channel: channel, payload: payload))

                case let .readyForQuery(status):
                    transactionStatus = status
                    let error = copyOutPendingError
                    endCopyOut()
                    if let error { throw PerunError.server(error) }
                    return nil

                default:
                    continue                     // CopyDone, CommandComplete, drained CopyData, acks
                }
            }
        } catch {
            if copyOutActive {
                if !isClosed { forceClose() }
                copyOutActive = false
            }
            throw error
        }
    }

    /// The consumer *broke out of* the copy (its `deinit`), rather than cancelling. Drain the
    /// server's remaining stream to resync and keep the connection — but bounded by
    /// `copyResyncTimeout`: a small remainder drains fast and the connection stays reusable; a large
    /// or slow one hits the bound and it is closed+discarded. No `CancelRequest` — it is async and
    /// per-backend and could strike the *next* borrower's query. Idempotent; the `generation` guard
    /// makes a late `deinit` a no-op once this copy has ended, so it can't tear down a newer copy.
    func finishCopyOut(generation: UInt64) async {
        guard copyOutActive, copyOutGeneration == generation else { return }
        copyOutTerminating = true
        let fd = self.fd
        let capped = min(max(copyResyncTimeout, .zero), .seconds(Int64(Int32.max)))
        let deadline = ContinuousClock().now + capped
        // Two bounds: `drainToReadyForQuery`'s in-loop deadline stops a fast *streaming* drain; the
        // watchdog's shutdown unblocks a *stalled* read. Mirrors connect()'s watchdog — cancel AND
        // await its value before any forceClose (so it can never shut a reused fd), and a fired
        // watchdog forces a discard even if the drain "reached" ReadyForQuery on the dead socket.
        let watchdog = Task<Bool, Never> {
            do { try await Task.sleep(for: capped) } catch { return false }
            SystemSocket.shutdownBoth(fd: fd)
            return true
        }
        func stopWatchdog() async -> Bool { watchdog.cancel(); return await watchdog.value }

        var resynced = false
        do { try await drainToReadyForQuery(deadline: deadline); resynced = true }
        catch { /* deadline, watchdog shutdown, or transport error → discard below */ }
        let fired = await stopWatchdog()
        if resynced, !fired {
            endCopyOut()                          // reached ReadyForQuery on a healthy socket: reusable
        } else {
            if !isClosed { forceClose() }         // large/slow remainder, or the watchdog shut it: discard
            copyOutActive = false
        }
    }

    private func endCopyOut() {
        guard copyOutActive else { return }
        copyOutActive = false
        copyOutTerminating = false
        copyOutPendingError = nil
        unlock()
    }

    /// Abandon an in-flight copyOut because the consuming task was cancelled: tear the connection
    /// down and discard it — promptly, no drain and no `CancelRequest`. `forceClose`'s synchronous
    /// `shutdownBoth` unblocks a read parked in `recv`. Guarded on generation so a stale cancel can't
    /// tear down a newer copy that reused the connection. (A plain break/deinit takes the bounded
    /// `finishCopyOut` drain instead, which keeps the connection when the remainder is cheap.)
    private func abandonCopyOutOnCancellation(generation: UInt64) {
        guard copyOutActive, copyOutGeneration == generation else { return }
        if !isClosed { forceClose() }
        copyOutActive = false
    }

    /// Route a copyOut teardown from the iterator's `deinit`. If the consuming task was cancelled —
    /// the common case where a `CancellationError` is thrown from the `for await` *body*, not caught
    /// inside `nextCopyData` — tear the connection down at once (`cancelled` is captured on the
    /// unwinding task, since this runs in a detached `Task` that wouldn't see the cancellation).
    /// Otherwise it was a plain `break`, so take the bounded drain that keeps a cheap remainder.
    func endCopyOutFromCleanup(generation: UInt64, cancelled: Bool) async {
        if cancelled {
            abandonCopyOutOnCancellation(generation: generation)
        } else {
            await finishCopyOut(generation: generation)
        }
    }

    // MARK: - COPY IN (client → server)
    //
    // `copyIn` holds the wire exclusively and reads inline: send the `COPY … FROM STDIN`
    // query, consume the CopyInResponse, hand the caller a writer whose writes are framed as
    // `CopyData`, then `CopyDone` (or `CopyFail` if the closure threw) and read the result.
    // The writer only works while `copyInActive`, so a leaked writer can't corrupt the wire.

    private var copyInActive = false
    private var copyInGeneration: UInt64 = 0          // identifies the current copyIn for its writer

    /// Consume the `CopyInResponse` handshake after a `COPY … FROM STDIN` query. Drains to
    /// ReadyForQuery and throws if the statement errored or wasn't a COPY FROM STDIN.
    private func readCopyInResponse() async throws {
        var pendingError: PostgresServerError?
        while true {
            switch try await readMessage() {
            case .copyInResponse:
                return                           // the server is ready to receive CopyData
            case .copyOutResponse:
                // Wrong direction: a COPY … TO STDOUT. The server streams to us; a COPY-out can't
                // be stopped in band, the stream can be huge or unbounded so draining it to reuse
                // the connection is costly, and an out-of-band cancel races the next query. Tear
                // the connection down — this is an API misuse, so discarding it is acceptable.
                forceClose()
                throw PerunError.copyMismatch("copyIn needs a COPY … FROM STDIN statement, not TO STDOUT")
            case let .errorResponse(error):
                pendingError = error
            case let .parameterStatus(name, value):
                parameters[name] = value
            case let .noticeResponse(notice):
                noticeHandler?(notice)
            case let .notificationResponse(processID, channel, payload):
                notificationContinuation.yield(
                    PostgresNotification(processID: processID, channel: channel, payload: payload))
            case let .readyForQuery(status):
                transactionStatus = status
                if let pendingError { throw PerunError.server(pendingError) }
                throw PerunError.copyMismatch("expected CopyInResponse (is the statement a COPY … FROM STDIN?)")
            default:
                continue
            }
        }
    }

    /// Send one `CopyData` chunk for the active `copyIn`. Guards on `copyInActive` *and* the
    /// writer's `generation`, so a writer used outside its own closure — including during a
    /// later `copyIn` on the same connection — is rejected rather than injecting bytes.
    func sendCopyData(_ bytes: [UInt8], generation: UInt64) async throws {
        guard copyInActive, copyInGeneration == generation else {
            throw PerunError.protocolViolation("COPY data written outside its copyIn")
        }
        guard !bytes.isEmpty else { return }
        // The CopyData frame length is an Int32; reject an oversized chunk rather than trap the
        // trapping Int32(_:) conversion inside frame(). Callers should chunk COPY data anyway.
        guard bytes.count <= Int(Int32.max) - 4 else { throw PerunError.valueTooLarge(bytes: bytes.count) }
        try await send(FrontendMessage.copyData(bytes))
    }

    /// Abort an in-progress `COPY … FROM STDIN` and drain to ReadyForQuery. The resulting
    /// ErrorResponse is the echo of our own `CopyFail`, so it is discarded — `copyIn`
    /// rethrows the original cause instead.
    private func failCopyIn() async throws {
        try await send(FrontendMessage.copyFail(message: "client aborted COPY"))
        try await drainToReadyForQuery()
    }

    /// Read and discard messages until ReadyForQuery, keeping session parameters and
    /// notifications current. Resynchronises the wire after aborting a COPY. With a `deadline`, a
    /// fast *streaming* drain gives up with `timedOut` once it passes (a *stalled* read, parked in
    /// `readMessage`, needs an out-of-band socket shutdown to unblock — the caller's watchdog).
    private func drainToReadyForQuery(deadline: ContinuousClock.Instant? = nil) async throws {
        while true {
            if let deadline, ContinuousClock().now >= deadline {
                throw PerunError.timedOut
            }
            switch try await readMessage() {
            case let .readyForQuery(status):
                transactionStatus = status
                return
            case let .parameterStatus(name, value):
                parameters[name] = value
            case let .noticeResponse(notice):
                noticeHandler?(notice)
            case let .notificationResponse(processID, channel, payload):
                notificationContinuation.yield(
                    PostgresNotification(processID: processID, channel: channel, payload: payload))
            default:
                continue
            }
        }
    }

    /// Close the connection and release its socket. Also interrupts any in-flight
    /// read — e.g. a `waitForNotifications` loop parked waiting for the next
    /// notification — so a listening connection can always be shut down.
    public func close() async throws {
        // Let an abandoned copyOut / row stream finish tearing down first. Its detached teardown Task
        // armed a watchdog that captured this fd; closing here frees the fd number (forceClose →
        // disconnect → close(fd)), so racing the teardown could let its watchdog `shutdownBoth` a
        // descriptor the OS has since reused for another connection. Awaiting the teardown guarantees
        // its watchdog is stopped before we free the fd. Synchronous accessor, so a no-op when nothing
        // is tearing down. (release() awaits the same tasks; this covers close() from every other path
        // — pool shutdown, discardAndReplaceIfNeeded, a direct caller.)
        for teardown in inFlightTeardownTasks() { await teardown.value }
        // A best-effort graceful Terminate lets the server do a clean backend exit instead of
        // logging "unexpected EOF on client connection" — but it must never stall teardown. If the
        // wire is wedged (the peer stopped reading, the send buffer is full, or the io queue is
        // already parked in a blocking send) the send would block indefinitely, so a watchdog shuts
        // the socket down after a short grace to make it return. Either way, forceClose then tears
        // the connection down — an immediate, out-of-band shutdown that never waits on the wire.
        if !isClosed {
            let fd = self.fd
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }   // sent in time: nothing to unblock
                SystemSocket.shutdownBoth(fd: fd)                                 // make the parked Terminate return
            }
            try? await send(FrontendMessage.terminate())
            watchdog.cancel()
            _ = await watchdog.value                                             // finish touching fd before forceClose
        }
        forceClose()
    }

    // MARK: - Handshake

    /// Session GUCs the driver pins so its **text** decoders read a known wire format: UTF-8
    /// strings, ISO dates/timestamps, and `postgres`-style intervals. Without these the
    /// output format follows the server / role / database default, which a text parser can't
    /// know. Each is applied only if the caller didn't set that GUC in `runtimeParameters`
    /// (matched case-insensitively, as PostgreSQL GUC names are), so a caller override still
    /// wins — at the cost of that type's text decoding (binary is unaffected, except that
    /// `client_encoding` still governs string bytes in both formats).
    private static let pinnedParameters = [
        "client_encoding": "UTF8",
        "DateStyle": "ISO",
        "IntervalStyle": "postgres",
    ]

    private func startup(_ configuration: ConnectionConfiguration,
                         deadline: ContinuousClock.Instant? = nil) async throws {
        // Start from the caller's parameters and add each pin only if the caller didn't
        // already set that GUC. The match is case-insensitive because PostgreSQL GUC names
        // are, so `["datestyle": …]` replaces the pinned `DateStyle` instead of both keys
        // ending up in the packet with an order-dependent winner.
        var startupParameters = configuration.runtimeParameters
        let callerGUCs = Set(configuration.runtimeParameters.keys.map { $0.lowercased() })
        for (key, value) in Self.pinnedParameters where !callerGUCs.contains(key.lowercased()) {
            startupParameters[key] = value
        }
        let startupMessage = try FrontendMessage.startup(
            user: configuration.user,
            database: configuration.database,
            parameters: startupParameters
        )
        try await send(startupMessage)

        loop: while true {
            let message = try await readMessage()
            switch message {
            case let .authentication(request):
                try await handleAuthentication(request, configuration: configuration, deadline: deadline)

            case let .parameterStatus(name, value):
                parameters[name] = value

            case let .backendKeyData(processID, secretKey):
                backendProcessID = processID
                backendSecretKey = secretKey

            case let .errorResponse(error):
                throw PerunError.server(error)

            case .noticeResponse:
                continue

            case let .readyForQuery(status):
                transactionStatus = status
                break loop

            default:
                continue
            }
        }
    }

    private func handleAuthentication(
        _ request: AuthenticationRequest,
        configuration: ConnectionConfiguration,
        deadline: ContinuousClock.Instant? = nil
    ) async throws {
        switch request {
        case .ok:
            // Authentication finished. If we were mid-SCRAM the server
            // signature must already have been verified.
            if let client = scram, !client.hasVerifiedServerSignature {
                throw PerunError.authenticationFailed("SCRAM exchange finished before server signature verification")
            }
            scram = nil
            return

        case .cleartextPassword:
            guard configuration.authenticationRequirement == .any else {
                throw PerunError.authenticationFailed(
                    "server requested cleartext password authentication, which the configuration forbids")
            }
            guard let password = configuration.password else {
                throw PerunError.authenticationFailed("server requires a password, none provided")
            }
            try await send(FrontendMessage.password(password))

        case let .md5Password(salt):
            guard configuration.authenticationRequirement != .scramOnly else {
                throw PerunError.authenticationFailed(
                    "server requested md5 authentication, but the configuration requires SCRAM")
            }
            guard let password = configuration.password else {
                throw PerunError.authenticationFailed("server requires a password, none provided")
            }
            // md5( md5(password + username) + salt ), prefixed with "md5".
            let inner = MD5.hexDigest(Array(password.utf8) + Array(configuration.user.utf8))
            let outer = MD5.hexDigest(Array(inner.utf8) + salt)
            try await send(FrontendMessage.password("md5" + outer))

        case let .sasl(mechanisms):
            guard mechanisms.contains(SCRAMClient.mechanism) else {
                throw PerunError.unsupportedAuthentication(
                    "server offered SASL mechanisms \(mechanisms), only \(SCRAMClient.mechanism) is supported")
            }
            guard let password = configuration.password else {
                throw PerunError.authenticationFailed("server requires a password, none provided")
            }
            var client = SCRAMClient(password: password)
            let clientFirst = client.clientFirstMessage()
            scram = client
            try await send(FrontendMessage.saslInitialResponse(
                mechanism: SCRAMClient.mechanism,
                initialResponse: Array(clientFirst.utf8)))

        case let .saslContinue(data):
            guard var client = scram else {
                throw PerunError.protocolViolation("SASLContinue without an active SCRAM exchange")
            }
            let serverFirst = String(decoding: data, as: UTF8.self)
            let clientFinal = try client.clientFinalMessage(serverFirst: serverFirst, deadline: deadline)
            scram = client
            try await send(FrontendMessage.saslResponse(Array(clientFinal.utf8)))

        case let .saslFinal(data):
            guard var client = scram else {
                throw PerunError.protocolViolation("SASLFinal without an active SCRAM exchange")
            }
            try client.verifyServerFinal(String(decoding: data, as: UTF8.self))
            scram = client
            // The trailing AuthenticationOk clears `scram`.

        case let .other(code):
            throw PerunError.unsupportedAuthentication("authentication code \(code)")
        }
    }

    // MARK: - Message framing

    /// Largest number of bytes requested from a single `recv`, so one declared
    /// message length can never drive an unbounded up-front allocation.
    static let readChunkSize = 65_536

    /// Validate a backend message's length field and return its payload length.
    /// The wire length includes its own 4 bytes; a value below 4 (including the
    /// negative that 0xFFFFFFFF decodes to) or above `maxMessageSize` is rejected
    /// before any buffer is sized to it.
    static func payloadLength(forMessageLength length: Int, maxMessageSize: Int) throws -> Int {
        guard length >= 4 else {
            throw PerunError.protocolViolation("message length \(length) is smaller than its 4-byte header")
        }
        let payload = length - 4
        guard payload <= maxMessageSize else {
            throw PerunError.protocolViolation(
                "message payload of \(payload) bytes exceeds the \(maxMessageSize)-byte limit")
        }
        return payload
    }

    /// Read one full backend message: a 1-byte tag, an Int32 length (which
    /// includes itself), then the payload.
    private func readMessage() async throws -> BackendMessage {
        let header = try await readSlice(5)
        var headerReader = ByteReader(header)
        let tag = try headerReader.readUInt8()
        let length = Int(try headerReader.readInt32())
        let payloadLength = try Self.payloadLength(forMessageLength: length, maxMessageSize: maxMessageSize)
        let payload = payloadLength > 0 ? try await readSlice(payloadLength) : readBuffer[readOffset ..< readOffset]
        let message = try BackendMessage.decode(tag: tag, payload: payload)
        compactReadBufferIfNeeded()
        return message
    }

    /// Return exactly `count` bytes as a slice into `readBuffer`, reading from
    /// the socket as needed.
    private func readSlice(_ count: Int) async throws -> ArraySlice<UInt8> {
        while readBuffer.count - readOffset < count {
            compactReadBufferIfNeeded()
            let needed = count - (readBuffer.count - readOffset)
            // Read ahead a little for efficiency, but never size a single recv to
            // the whole remaining message — that is the OOM guard's other half.
            let chunk = try await receive(maxLength: min(max(needed, 8192), Self.readChunkSize))
            if chunk.isEmpty {
                throw PerunError.connectionClosed
            }
            readBuffer.append(contentsOf: chunk)
        }

        let result = readBuffer[readOffset ..< readOffset + count]
        readOffset += count
        return result
    }

    private func compactReadBufferIfNeeded() {
        // Reclaim consumed prefix once it grows large, keeping memory bounded.
        if readOffset > 65_536 {
            readBuffer.removeFirst(readOffset)
            readOffset = 0
        }
    }

    // MARK: - Raw I/O (bridged off the cooperative pool)

    private func send(_ bytes: [UInt8]) async throws {
        guard !isClosed else { throw PerunError.connectionClosed }
        let fd = self.fd
        let tls = self.tls
        do {
            try await withBlockingIO(on: ioQueue) {
                if let tls {
                    try tls.send(bytes)
                } else {
                    try SystemSocket.sendAll(fd: fd, bytes)
                }
            }
        } catch let error as SocketError {
            // A raw socket failure isn't a PerunError, so classify it as a wire desync — the pool
            // must discard this connection, not reuse it (the TLS path throws .tlsIO likewise).
            throw PerunError.ioError(error.description)
        }
    }

    private func receive(maxLength: Int) async throws -> [UInt8] {
        guard !isClosed else { throw PerunError.connectionClosed }
        let fd = self.fd
        let tls = self.tls
        do {
            return try await withBlockingIO(on: readQueue) {
                if let tls {
                    return try tls.receive(maxLength: maxLength)
                } else {
                    return try SystemSocket.receive(fd: fd, maxLength: maxLength)
                }
            }
        } catch let error as SocketError {
            throw PerunError.ioError(error.description)   // classify a raw socket failure as a wire desync
        }
    }

    /// A cheap, non-blocking liveness probe for a pooled connection between uses — returns
    /// false if it is closed, the peer closed the socket, or unsolicited data is already
    /// waiting (a fully-drained connection should have none; a server that closed the
    /// backend while it sat idle typically leaves a termination `ErrorResponse` the parked
    /// reader never saw). Best-effort — the connection could still die right after — but it
    /// catches the common stale-idle case without a round trip. Peeks on the read queue so
    /// it cannot race the background reader.
    func isProbablyAlive() async -> Bool {
        guard !isClosed else { return false }
        // Unconsumed framed bytes already sit *above* the socket: readSlice reads ahead, so a read
        // carrying ReadyForQuery plus one or more following messages can land wholly in readBuffer
        // while the socket and OpenSSL below read empty. These are decoded frames, so — unlike the raw
        // socket peek below — we *can* classify them: a buffered async message (NotificationResponse
        // 'A' / NoticeResponse 'N' / ParameterStatus 'S') is benign, the reader consumes it next, so
        // keep; anything else (e.g. a termination 'E') is a desync. One benign 'A' can shadow a
        // following 'E' in the *same* buffer, so walk every fully-buffered frame, not just the first
        // tag. A partly-buffered trailing frame is
        // safe to ignore — the reader will complete it. Decoded bytes, so this holds for TLS too.
        var pos = readOffset
        while pos < readBuffer.count {
            switch readBuffer[pos] {
            case UInt8(ascii: "A"), UInt8(ascii: "N"), UInt8(ascii: "S"):
                break                      // benign async tag — advance past this frame and check the next
            default:
                return false               // a non-async message (e.g. a termination 'E') is already queued
            }
            guard pos + 5 <= readBuffer.count else { break }   // partial header: incomplete trailing frame, safe
            // Read the length as a signed Int32 and validate it exactly as the framing decoder does, so a
            // garbage value (the negative that 0xFFFFFFFF decodes to, or one past maxMessageSize) reads as
            // a desync — not a benign "incomplete" frame that would let a following 'E' hide behind it.
            let raw = (UInt32(readBuffer[pos + 1]) << 24) | (UInt32(readBuffer[pos + 2]) << 16)
                    | (UInt32(readBuffer[pos + 3]) << 8) | UInt32(readBuffer[pos + 4])
            let length = Int(Int32(bitPattern: raw))
            guard (try? Self.payloadLength(forMessageLength: length, maxMessageSize: maxMessageSize)) != nil else {
                return false
            }
            let frameEnd = pos + 1 + length
            if frameEnd > readBuffer.count { break }           // valid length but body not fully buffered: safe
            // Fully buffered: framing alone isn't enough — an 'A' with a valid length but an empty payload
            // frames cleanly yet is no real NotificationResponse. Run it through the same decoder the reader
            // uses (the single source of protocol truth); a frame it rejects is a desync we must discard.
            guard frameDecodesAsBenignAsync(pos: pos, frameEnd: frameEnd) else { return false }
            pos = frameEnd
        }
        let fd = self.fd
        let tls = self.tls
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            readQueue.async {
                // Over TLS the raw peek can't see bytes OpenSSL already pulled off the socket — decrypted
                // in its buffer, or ciphertext waiting in the read BIO — so check those too. Done on the
                // read queue, like SSL_read, so it can't race the background reader.
                if let tls, tls.pendingBytes() != 0 {
                    continuation.resume(returning: false)
                } else {
                    continuation.resume(returning: SystemSocket.isQuiescentOpen(fd: fd))
                }
            }
        }
    }

    /// Whether the fully-buffered frame at `pos ..< frameEnd` decodes — through `BackendMessage.decode`,
    /// the same decoder the reader uses — as a benign async message (NotificationResponse, NoticeResponse,
    /// or ParameterStatus). A frame that frames cleanly but the decoder rejects (e.g. an 'A' whose payload
    /// carries no PID or strings) is a desync, so this returns false and the liveness probe discards it.
    private func frameDecodesAsBenignAsync(pos: Int, frameEnd: Int) -> Bool {
        guard let message = try? BackendMessage.decode(tag: readBuffer[pos],
                                                       payload: readBuffer[(pos + 5) ..< frameEnd]) else {
            return false
        }
        switch message {
        case .notificationResponse, .noticeResponse, .parameterStatus: return true
        default: return false
        }
    }

    #if DEBUG
    /// Test seam: prime the TLS read BIO with `count` bytes to simulate ciphertext the last read
    /// pulled ahead. Returns false on a plaintext connection (nothing to prime).
    func primeTLSReadBufferForTest(_ count: Int) -> Bool {
        guard let tls else { return false }
        tls.primeReadBIOForTest(count)
        return true
    }

    /// Test seam: leave one framing-complete, empty-payload (length-4) message per tag unconsumed in the
    /// driver's own read buffer, standing in for a read-ahead that pulled trailing messages in alongside
    /// the last one. Multiple tags stack into one buffer. The empty payload is fine for a tag the probe
    /// rejects outright (e.g. 'E') or for priming a malformed async frame the decoder must reject; a
    /// decodable benign message needs a real payload — use `primeReadBufferRawForTest(notificationFrame())`.
    func primeReadBufferForTest(_ tags: [UInt8]) {
        for tag in tags { readBuffer.append(contentsOf: [tag, 0, 0, 0, 4]) }
    }

    /// Test seam: append arbitrary raw bytes to the read buffer, for priming a frame the framed
    /// `primeReadBufferForTest` can't express — a real async payload, or a malformed/oversized header.
    func primeReadBufferRawForTest(_ bytes: [UInt8]) {
        readBuffer.append(contentsOf: bytes)
    }
    #endif

    /// Tear the connection down if `error` may have left the wire out of sync, so an inline
    /// (exclusive-path) reader — copyIn, copyOut, queryStream setup, a transaction — doesn't
    /// leave a half-consumed message behind for the next caller. The shared, pipelined path
    /// already does this centrally in `readerLoop`.
    private func forceCloseIfDesynced(_ error: Error) {
        if let perun = error as? PerunError, perun.mayHaveDesynchronizedWire, !isClosed {
            forceClose()
        }
    }

    private func forceClose() {
        guard !isClosed else { return }
        isClosed = true
        notificationContinuation.finish()
        failAllPendingReads(PerunError.connectionClosed)   // fail everything the reader still owes
        failAllAccessWaiters(PerunError.connectionClosed)  // and everyone parked for wire access
        let fd = self.fd
        let tls = self.tls
        let readQueue = self.readQueue
        self.tls = nil
        // Shut the socket down from here so any recv parked on readQueue (or send parked on
        // ioQueue) returns; otherwise the teardown dispatched below would queue behind it.
        SystemSocket.shutdownBoth(fd: fd)
        // Free the TLS engine and the fd only after both I/O queues have drained: hop
        // ioQueue → readQueue so any already-dispatched write finishes before the fd is
        // closed, otherwise a queued write could land on a descriptor the OS has since reused.
        // `isClosed` is already set, so no new writes are dispatched; `tls.close()` is
        // internally locked, so it can't race an in-flight SSL_read/SSL_write.
        ioQueue.async {
            readQueue.async {
                tls?.close()
                SystemSocket.disconnect(fd: fd)
            }
        }
    }

    deinit {
        // Safety net for a connection dropped without close(): because the reader exits when idle
        // rather than parking, it no longer pins this actor alive, so a forgotten connection
        // reaches deinit — free its socket here instead of leaking the fd (and reader task/buffers).
        guard !isClosed else { return }
        notificationContinuation.finish()
        let fd = self.fd
        let tls = self.tls
        let readQueue = self.readQueue
        let ioQueue = self.ioQueue
        SystemSocket.shutdownBoth(fd: fd)
        ioQueue.async {
            readQueue.async {
                tls?.close()
                SystemSocket.disconnect(fd: fd)
            }
        }
    }
}
