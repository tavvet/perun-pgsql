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

/// Everything needed to open a connection.
public struct ConnectionConfiguration: Sendable {
    public var host: String
    public var port: UInt16
    public var user: String
    public var database: String
    public var password: String?
    /// How to negotiate TLS. Defaults to `.verifyFull`.
    public var tlsMode: TLSMode
    /// Reject any backend message whose payload exceeds this many bytes. Bounds
    /// memory against a malicious or buggy server that declares a huge length.
    /// Defaults to 256 MiB.
    public var maxMessageSize: Int
    /// Maximum number of LISTEN/NOTIFY messages buffered when the consumer is
    /// slower than the socket pump. Newer notifications replace older buffered
    /// ones once this limit is reached. Defaults to 1024.
    public var notificationBufferLimit: Int
    /// Extra startup parameters (e.g. `["application_name": "perun"]`).
    public var runtimeParameters: [String: String]

    public init(host: String = "localhost",
                port: UInt16 = 5432,
                user: String,
                database: String,
                password: String? = nil,
                tlsMode: TLSMode = .verifyFull,
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
        self.maxMessageSize = maxMessageSize
        self.notificationBufferLimit = notificationBufferLimit
        self.runtimeParameters = runtimeParameters
    }
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
    /// Reject backend messages whose payload exceeds this many bytes (DoS guard).
    private let maxMessageSize: Int
    /// Process-local identity used to keep prepared-statement handles scoped to
    /// the backend connection that created them.
    private let connectionID: UInt64

    /// The TLS channel, once negotiated. When non-nil, all I/O flows through it.
    private var tls: TLSConnection?

    /// Stream of asynchronous LISTEN/NOTIFY notifications from the server.
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
                 maxMessageSize: Int,
                 notificationBufferLimit: Int) {
        self.fd = fd
        self.ioQueue = ioQueue
        self.readQueue = DispatchQueue(label: "perun.connection.read")
        self.host = host
        self.port = port
        self.maxMessageSize = maxMessageSize
        self.connectionID = UInt64.random(in: UInt64.min ... UInt64.max)
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
        let fd = try await withBlockingIO(on: ioQueue) {
            try SystemSocket.makeConnected(host: configuration.host, port: configuration.port)
        }
        let connection = PostgresConnection(fd: fd, ioQueue: ioQueue,
                                            host: configuration.host, port: configuration.port,
                                            maxMessageSize: configuration.maxMessageSize,
                                            notificationBufferLimit: configuration.notificationBufferLimit)
        do {
            if configuration.tlsMode != .disable {
                try await connection.negotiateTLS(configuration)
            }
            try await connection.startup(configuration)
        } catch {
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

    /// Run one Simple Query request. The string may contain multiple
    /// statements; the result reflects the last statement that produced rows.
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
            streamPortal = portal
            streamChunkSize = chunk
            streamColumns = []
            streamColumnIndex = [:]
            streamTerminating = false
            streamPendingError = nil
            return PostgresRowStream(connection: self)
        } catch {
            unlock()
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

        _ = try await runSimpleQuery("BEGIN")
        do {
            let result = try await body(Transaction(connection: self, contextID: contextID))
            _ = try await runSimpleQuery("COMMIT")
            return result
        } catch {
            _ = try? await runSimpleQuery("ROLLBACK")
            throw error
        }
    }

    private func validateTransactionContext(_ contextID: Int) throws {
        guard activeTransactionContext == contextID else {
            throw PerunError.protocolViolation("transaction context is no longer active")
        }
    }

    private func runTransactionSimpleQuery(_ sql: String, contextID: Int) async throws -> QueryResult {
        try validateTransactionContext(contextID)
        return try await runSimpleQuery(sql)
    }

    private func runTransactionParameterizedQuery(_ sql: String,
                                                  _ parameters: [(any PostgresEncodable)?],
                                                  parameterFormat: PostgresFormat,
                                                  resultFormat: PostgresFormat,
                                                  contextID: Int) async throws -> QueryResult {
        try validateTransactionContext(contextID)
        return try await runParameterizedQuery(sql, parameters,
                                               parameterFormat: parameterFormat,
                                               resultFormat: resultFormat)
    }

    private func runTransactionPrepare(_ sql: String, contextID: Int) async throws -> PreparedStatement {
        try validateTransactionContext(contextID)
        return try await runPrepare(sql)
    }

    private func runTransactionExecute(_ statement: PreparedStatement,
                                       _ parameters: [(any PostgresEncodable)?],
                                       parameterFormat: PostgresFormat,
                                       resultFormat: PostgresFormat,
                                       contextID: Int) async throws -> QueryResult {
        try validateTransactionContext(contextID)
        return try await runExecute(statement, parameters,
                                    parameterFormat: parameterFormat,
                                    resultFormat: resultFormat)
    }

    private func runTransactionClosePrepared(_ statement: PreparedStatement,
                                             contextID: Int) async throws {
        try validateTransactionContext(contextID)
        try await runClosePrepared(statement)
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
    public func waitForNotifications() async throws {
        try await lock(); defer { unlock() }
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
        // A dedicated queue and a *separate* socket: this connection may be parked in a
        // blocking recv waiting for the very query we're trying to cancel.
        let cancelQueue = DispatchQueue(label: "perun.cancel")
        try await withBlockingIO(on: cancelQueue) {
            let fd = try SystemSocket.makeConnected(host: host, port: port)
            defer { SystemSocket.disconnect(fd: fd) }
            try SystemSocket.sendAll(fd: fd,
                                     FrontendMessage.cancelRequest(processID: processID, secretKey: secretKey))
        }
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
                rowValues.append(values)

            case let .commandComplete(tag):
                results.append(QueryResult(columns: columns, values: rowValues, commandTag: tag))
                columns = defaultColumns
                rowValues = []

            case .emptyQueryResponse:
                results.append(QueryResult(columns: defaultColumns, values: [], commandTag: ""))
                columns = defaultColumns
                rowValues = []

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
    private var readerWaiter: CheckedContinuation<Void, Never>?
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
                    wakeReader()
                    kickWrite(request)
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
        guard !readerStarted else { return }
        readerStarted = true
        Task { await self.readerLoop() }
    }

    /// Deliver responses in FIFO order. Pops each read *before* running it, so teardown
    /// can never double-resume the one in flight. A wire-desync error tears the
    /// connection down and fails everything still queued.
    private func readerLoop() async {
        while !isClosed {
            if pendingReads.isEmpty {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if pendingReads.isEmpty && !isClosed {
                        readerWaiter = continuation
                    } else {
                        continuation.resume()
                    }
                }
                continue
            }
            let op = pendingReads.removeFirst()
            currentRead = op                             // the request the backend is running now
            let inSync = await op.run()
            currentRead = nil
            if inSync == false {
                forceClose()
                break
            }
        }
        failAllPendingReads(PerunError.connectionClosed)
    }

    private func wakeReader() {
        if let waiter = readerWaiter {
            readerWaiter = nil
            waiter.resume()
        }
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
        var commandTag = ""
        var pendingError: PostgresServerError?

        loop: while true {
            let message = try await readMessage()
            switch message {
            case let .rowDescription(fields):
                columns = fields.map(ColumnMetadata.init)
                rowValues.removeAll(keepingCapacity: true)

            case let .dataRow(values):
                rowValues.append(values)

            case let .commandComplete(tag):
                commandTag = tag

            case .emptyQueryResponse:
                commandTag = ""

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
        return QueryResult(columns: columns, values: rowValues, commandTag: commandTag)
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

    /// The consumer pulled the next row. Read inline until a DataRow (return it), the end
    /// (ReadyForQuery → nil), or an error. Chunk boundaries are crossed transparently: a
    /// PortalSuspended asks for the next chunk; a CommandComplete closes the portal.
    func nextStreamRow() async throws -> PostgresRow? {
        guard streamActive else { return nil }
        do {
            while true {
                let message = try await readMessage()
                switch message {
                case let .dataRow(values) where !streamTerminating:
                    return PostgresRow(values: values, columns: streamColumns, columnIndexByName: streamColumnIndex)

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
    /// stream consumed to its end already finished, so this is a no-op.
    func finishStream() async {
        guard streamActive else { return }
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

    /// Close the connection and release its socket. Also interrupts any in-flight
    /// read — e.g. a `waitForNotifications` loop parked waiting for the next
    /// notification — so a listening connection can always be shut down.
    public func close() async throws {
        forceClose()
    }

    // MARK: - Handshake

    private func startup(_ configuration: ConnectionConfiguration) async throws {
        let startupMessage = FrontendMessage.startup(
            user: configuration.user,
            database: configuration.database,
            parameters: configuration.runtimeParameters
        )
        try await send(startupMessage)

        loop: while true {
            let message = try await readMessage()
            switch message {
            case let .authentication(request):
                try await handleAuthentication(request, configuration: configuration)

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
        configuration: ConnectionConfiguration
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
            guard let password = configuration.password else {
                throw PerunError.authenticationFailed("server requires a password, none provided")
            }
            try await send(FrontendMessage.password(password))

        case let .md5Password(salt):
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
            let clientFinal = try client.clientFinalMessage(serverFirst: serverFirst)
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
        try await withBlockingIO(on: ioQueue) {
            if let tls {
                try tls.send(bytes)
            } else {
                try SystemSocket.sendAll(fd: fd, bytes)
            }
        }
    }

    private func receive(maxLength: Int) async throws -> [UInt8] {
        guard !isClosed else { throw PerunError.connectionClosed }
        let fd = self.fd
        let tls = self.tls
        return try await withBlockingIO(on: readQueue) {
            if let tls {
                return try tls.receive(maxLength: maxLength)
            } else {
                return try SystemSocket.receive(fd: fd, maxLength: maxLength)
            }
        }
    }

    private func forceClose() {
        guard !isClosed else { return }
        isClosed = true
        notificationContinuation.finish()
        failAllPendingReads(PerunError.connectionClosed)   // fail everything the reader still owes
        failAllAccessWaiters(PerunError.connectionClosed)  // and everyone parked for wire access
        wakeReader()                                        // and let a parked reader loop exit
        let fd = self.fd
        let tls = self.tls
        self.tls = nil
        // Shut the socket down from here so any recv parked on readQueue returns;
        // otherwise the teardown dispatched below would queue behind it forever.
        SystemSocket.shutdownBoth(fd: fd)
        readQueue.async {
            tls?.close()
            SystemSocket.disconnect(fd: fd)
        }
    }
}
