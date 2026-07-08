/// A pool of PostgreSQL connections.
///
/// `PostgresClient` lazily opens up to `maxConnections` connections and hands
/// them out one at a time. Callers either grab one with `withConnection` or use
/// the convenience `query` methods, which check a connection out, run, and
/// return it automatically. Each `query` call is its own autocommit unit; use
/// `withTransaction` when several statements must run atomically on one
/// connection.
///
/// ```swift
/// let pool = PostgresClient(configuration: config, maxConnections: 8)
/// let rows = try await pool.query("SELECT * FROM users WHERE id = $1", [id]).rows
/// // …fan out concurrently; the pool serialises access…
/// try await pool.shutdown()
/// ```
public actor PostgresClient {
    private let configuration: ConnectionConfiguration
    private let maxConnections: Int

    /// Idle, ready-to-use connections.
    private var idle: [PostgresConnection] = []
    /// How many connections currently exist (idle + checked out + connecting).
    private var openCount = 0
    /// Tasks parked waiting for a connection to free up.
    private var waiters: [CheckedContinuation<PostgresConnection, Error>] = []
    private var isShutDown = false

    public init(configuration: ConnectionConfiguration, maxConnections: Int = 10) {
        precondition(maxConnections > 0, "maxConnections must be positive")
        self.configuration = configuration
        self.maxConnections = maxConnections
    }

    /// Number of connections currently open (idle plus in use).
    public var connectionCount: Int { openCount }

    // MARK: - Running work on a pooled connection

    /// Check out a connection, run `body`, and return the connection to the pool.
    ///
    /// On a server-side (SQL) error the connection is healthy and is reused; on a
    /// transport/protocol error it is discarded and replaced.
    public nonisolated func withConnection<T: Sendable>(
        _ body: (PostgresConnection) async throws -> T
    ) async throws -> T {
        let connection = try await acquire()
        do {
            let result = try await body(connection)
            await release(connection)
            return result
        } catch {
            await releaseAfterError(connection, error: error)
            throw error
        }
    }

    /// Convenience: run a (optionally parameterized) query on a pooled connection.
    @discardableResult
    public nonisolated func query(_ sql: String,
                                  _ parameters: [(any PostgresEncodable)?] = [],
                                  resultFormat: PostgresFormat = .text) async throws -> QueryResult {
        try await withConnection { connection in
            try await connection.query(sql, parameters, resultFormat: resultFormat)
        }
    }

    /// Check out one connection, run `body` in a transaction, then return the
    /// connection only after COMMIT or ROLLBACK has completed.
    public nonisolated func withTransaction<T: Sendable>(
        _ body: @Sendable (PostgresConnection.Transaction) async throws -> T
    ) async throws -> T {
        try await withConnection { connection in
            try await connection.withTransaction(body)
        }
    }

    /// Close every connection and fail anyone still waiting. Idempotent.
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true

        let toClose = idle
        idle.removeAll()
        for connection in toClose {
            try? await connection.close()
        }
        openCount -= toClose.count

        let parked = waiters
        waiters.removeAll()
        for waiter in parked {
            waiter.resume(throwing: PerunError.clientShutdown)
        }
        // Connections still checked out are closed when they are released.
    }

    // MARK: - Pool internals

    private func acquire() async throws -> PostgresConnection {
        if isShutDown { throw PerunError.clientShutdown }

        if let reused = idle.popLast() {
            return reused
        }

        if openCount < maxConnections {
            openCount += 1
            do {
                let connection = try await PostgresConnection.connect(configuration)
                if isShutDown {
                    try? await connection.close()
                    throw PerunError.clientShutdown
                }
                return connection
            } catch {
                openCount -= 1
                throw error
            }
        }

        // At capacity — wait for a connection to come back.
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release(_ connection: PostgresConnection) async {
        if isShutDown {
            closeDuringShutdown(connection)
            return
        }
        let status = await connection.transactionStatus
        // Re-check: shutdown() may have run — and drained `idle` — while we were
        // suspended on the await above. Without this we would append to an
        // already-torn-down pool and leak the connection.
        if isShutDown {
            closeDuringShutdown(connection)
            return
        }
        guard status == .idle else {
            await discardAndReplaceIfNeeded(connection)
            return
        }
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: connection)   // hand straight to a waiter
        } else {
            idle.append(connection)
        }
    }

    private func closeDuringShutdown(_ connection: PostgresConnection) {
        openCount -= 1
        Task { try? await connection.close() }
    }

    private func releaseAfterError(_ connection: PostgresConnection, error: Error) async {
        // Only errors that may have left the wire out of sync require dropping the
        // connection. A server (SQL) error, a decode/local error, or an error from
        // the caller's own closure all surface after the query drained to
        // ReadyForQuery, so the connection is reusable — release() still discards
        // it if it came back mid-transaction.
        if let perun = error as? PerunError, perun.mayHaveDesynchronizedWire {
            await discardAndReplaceIfNeeded(connection)
        } else {
            await release(connection)
        }
    }

    private func discardAndReplaceIfNeeded(_ connection: PostgresConnection) async {
        openCount -= 1
        try? await connection.close()
        guard !isShutDown, !waiters.isEmpty, openCount < maxConnections else { return }
        let waiter = waiters.removeFirst()
        openCount += 1
        do {
            let replacement = try await PostgresConnection.connect(configuration)
            if isShutDown {
                openCount -= 1
                try? await replacement.close()
                waiter.resume(throwing: PerunError.clientShutdown)
                return
            }
            waiter.resume(returning: replacement)
        } catch {
            openCount -= 1
            waiter.resume(throwing: error)
        }
    }
}

private extension PerunError {
    /// Whether this error may have left the connection's wire out of sync, so a
    /// pooled connection that hit it must be discarded rather than reused.
    var mayHaveDesynchronizedWire: Bool {
        switch self {
        case .connectionClosed, .protocolViolation, .tlsHandshakeFailed, .tlsIO,
             .tlsNotAvailable, .authenticationFailed, .unsupportedAuthentication:
            return true
        case .server, .unexpectedNull, .columnNotFound, .decodingFailed, .tooManyParameters,
             .clientShutdown, .preparedStatementConnectionMismatch:
            return false
        }
    }
}
