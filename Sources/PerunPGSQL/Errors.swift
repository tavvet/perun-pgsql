/// A structured error reported by the PostgreSQL server (an `ErrorResponse`).
///
/// The fields are the raw single-byte-tagged strings from the protocol; the
/// computed properties expose the common ones. See the PostgreSQL protocol
/// docs, "Error and Notice Message Fields".
public struct PostgresServerError: Error, Sendable, CustomStringConvertible {
    /// Raw fields keyed by their single-byte type code (e.g. `S`, `C`, `M`).
    public let fields: [UInt8: String]

    init(fields: [UInt8: String]) {
        self.fields = fields
    }

    private func field(_ char: Character) -> String? {
        fields[char.asciiValue!]
    }

    /// Severity: `ERROR`, `FATAL`, `PANIC`, `WARNING`, …
    public var severity: String? { field("S") }
    /// The raw five-character SQLSTATE code, e.g. `23505`. Use `sqlState` for a typed,
    /// switchable value; this is the escape hatch for codes the driver does not name.
    public var sqlStateCode: String? { field("C") }
    /// The SQLSTATE as a typed condition. This is the stable signal to branch on —
    /// unknown codes map to `.other`, preserving the raw string.
    public var sqlState: SQLState? { sqlStateCode.map { SQLState(code: $0) } }
    /// Primary human-readable message. Localized (via `lc_messages`) and version-
    /// dependent: branch on `sqlState`, never parse this text.
    public var message: String? { field("M") }
    /// Optional secondary detail.
    public var detail: String? { field("D") }
    /// Optional hint on how to fix it.
    public var hint: String? { field("H") }

    /// Name of the constraint the error relates to — e.g. the unique index behind a
    /// `uniqueViolation`, which turns "some unique error" into "this exact one".
    public var constraintName: String? { field("n") }
    /// Schema / table / column / data-type name the error relates to, when reported.
    public var schemaName: String? { field("s") }
    public var tableName: String? { field("t") }
    public var columnName: String? { field("c") }
    public var dataTypeName: String? { field("d") }
    /// 1-based character position of the error within the original query text.
    public var position: Int? { field("P").flatMap { Int($0) } }
    /// The call-stack "where" context of the error, if any.
    public var context: String? { field("W") }

    public var description: String {
        let sev = severity ?? "ERROR"
        let code = sqlStateCode.map { " [\($0)]" } ?? ""
        var text = "\(sev)\(code): \(message ?? "(no message)")"
        if let detail { text += " — \(detail)" }
        if let hint { text += " (hint: \(hint))" }
        return text
    }
}

/// A typed PostgreSQL SQLSTATE condition.
///
/// Only the codes callers commonly branch on are named; everything else is
/// `.other(code)`, keeping the raw five-character string. SQLSTATE is the SQL-standard,
/// stable error signal (unlike the localized `message`), so this is what you switch on.
/// The driver reports the condition; mapping it to a domain error — "this unique
/// violation means the email is taken" — is the caller's job.
public enum SQLState: Sendable, Equatable, Hashable {
    // Class 22 — data exception
    case numericValueOutOfRange          // 22003
    case invalidTextRepresentation       // 22P02

    // Class 23 — integrity constraint violation
    case notNullViolation                // 23502
    case foreignKeyViolation             // 23503
    case uniqueViolation                 // 23505
    case checkViolation                  // 23514
    case exclusionViolation              // 23P01

    // Class 28 — invalid authorization specification
    case invalidPassword                 // 28P01

    // Class 40 — transaction rollback (transient; a caller may retry)
    case serializationFailure            // 40001
    case deadlockDetected                // 40P01

    // Class 42 — syntax error or access rule violation
    case syntaxError                     // 42601
    case insufficientPrivilege           // 42501
    case undefinedColumn                 // 42703
    case undefinedTable                  // 42P01
    case undefinedFunction               // 42883
    case duplicateTable                  // 42P07

    // Class 53 — insufficient resources
    case tooManyConnections              // 53300

    // Class 55 — object not in prerequisite state
    case lockNotAvailable                // 55P03

    // Class 57 — operator intervention
    case queryCanceled                   // 57014
    case adminShutdown                   // 57P01
    case cannotConnectNow                // 57P03

    /// Any SQLSTATE the driver does not name, carrying the raw five-character code.
    case other(String)

    public init(code: String) {
        switch code {
        case "22003": self = .numericValueOutOfRange
        case "22P02": self = .invalidTextRepresentation
        case "23502": self = .notNullViolation
        case "23503": self = .foreignKeyViolation
        case "23505": self = .uniqueViolation
        case "23514": self = .checkViolation
        case "23P01": self = .exclusionViolation
        case "28P01": self = .invalidPassword
        case "40001": self = .serializationFailure
        case "40P01": self = .deadlockDetected
        case "42601": self = .syntaxError
        case "42501": self = .insufficientPrivilege
        case "42703": self = .undefinedColumn
        case "42P01": self = .undefinedTable
        case "42883": self = .undefinedFunction
        case "42P07": self = .duplicateTable
        case "53300": self = .tooManyConnections
        case "55P03": self = .lockNotAvailable
        case "57014": self = .queryCanceled
        case "57P01": self = .adminShutdown
        case "57P03": self = .cannotConnectNow
        default:      self = .other(code)
        }
    }

    /// The raw five-character SQLSTATE code.
    public var code: String {
        switch self {
        case .numericValueOutOfRange: return "22003"
        case .invalidTextRepresentation: return "22P02"
        case .notNullViolation: return "23502"
        case .foreignKeyViolation: return "23503"
        case .uniqueViolation: return "23505"
        case .checkViolation: return "23514"
        case .exclusionViolation: return "23P01"
        case .invalidPassword: return "28P01"
        case .serializationFailure: return "40001"
        case .deadlockDetected: return "40P01"
        case .syntaxError: return "42601"
        case .insufficientPrivilege: return "42501"
        case .undefinedColumn: return "42703"
        case .undefinedTable: return "42P01"
        case .undefinedFunction: return "42883"
        case .duplicateTable: return "42P07"
        case .tooManyConnections: return "53300"
        case .lockNotAvailable: return "55P03"
        case .queryCanceled: return "57014"
        case .adminShutdown: return "57P01"
        case .cannotConnectNow: return "57P03"
        case let .other(code): return code
        }
    }

    /// The two-character SQLSTATE class, e.g. `23` for integrity-constraint errors.
    public var errorClass: String { String(code.prefix(2)) }

    /// True for the integrity-constraint-violation class (`23…`): unique, foreign-key,
    /// not-null, check and exclusion violations.
    public var isIntegrityConstraintViolation: Bool { errorClass == "23" }

    /// True for the transaction-rollback class (`40…`) — `serializationFailure` and
    /// `deadlockDetected`. These are transient; whether to retry is the caller's policy.
    public var isTransactionRollback: Bool { errorClass == "40" }
}

/// Everything the driver itself can throw.
public enum PerunError: Error, CustomStringConvertible, Sendable {
    /// The server sent something that violates the wire protocol, or a message
    /// was truncated.
    case protocolViolation(String)
    /// The connection was closed unexpectedly (EOF mid-message).
    case connectionClosed
    /// A low-level socket read or write failed (e.g. the peer reset the connection). Like a
    /// mid-message close it leaves the wire's state unknown, so a pooled connection that hits it
    /// is discarded rather than reused.
    case ioError(String)
    /// The connection could not be established — host resolution or the TCP connect failed.
    /// Thrown by `connect`, before any wire exists.
    case connectionFailed(String)
    /// A structured error from the server.
    case server(PostgresServerError)
    /// The server asked for an authentication method we do not implement yet.
    case unsupportedAuthentication(String)
    /// Authentication was attempted but failed on our side (e.g. missing
    /// password, bad SASL exchange).
    case authenticationFailed(String)
    /// A non-optional value was requested from a column that held SQL NULL.
    case unexpectedNull(column: String)
    /// A row was accessed by a column name that was not present in the result.
    case columnNotFound(String)
    /// A column's bytes could not be decoded into the requested Swift type.
    case decodingFailed(type: String, oid: Int32, format: String, reason: String)
    /// The TLS handshake failed (or the certificate did not verify).
    case tlsHandshakeFailed(String)
    /// An error occurred reading or writing over the established TLS channel.
    case tlsIO(String)
    /// TLS was required but the server does not support it.
    case tlsNotAvailable
    /// An operation was requested on a pool that has been shut down.
    case clientShutdown
    /// More parameters than the protocol's unsigned 16-bit count field allows (max 65535).
    case tooManyParameters(count: Int)
    /// A prepared-statement handle was used on a different connection than the
    /// one that created it.
    case preparedStatementConnectionMismatch
    /// A COPY was started on a statement of the wrong kind — `copyOut` on a `COPY … FROM STDIN`,
    /// `copyIn` on a `COPY … TO STDOUT`, or either on a non-COPY statement. The handshake is
    /// drained to ReadyForQuery first, so the connection stays in sync and is kept.
    case copyMismatch(String)
    /// An operation wrapped in `withTimeout` did not finish before its deadline. The
    /// underlying query was cancelled (a `CancelRequest`), so the connection stays usable.
    case timedOut

    public var description: String {
        switch self {
        case let .protocolViolation(detail):
            return "protocol violation: \(detail)"
        case .connectionClosed:
            return "connection closed by server"
        case let .ioError(detail):
            return "I/O error: \(detail)"
        case let .connectionFailed(detail):
            return "could not connect: \(detail)"
        case let .server(error):
            return error.description
        case let .unsupportedAuthentication(detail):
            return "unsupported authentication method: \(detail)"
        case let .authenticationFailed(detail):
            return "authentication failed: \(detail)"
        case let .unexpectedNull(column):
            return "unexpected NULL decoding column \"\(column)\""
        case let .columnNotFound(column):
            return "column \"\(column)\" was not found in this row"
        case let .decodingFailed(type, oid, format, reason):
            return "could not decode \(type) from \(format) OID \(oid): \(reason)"
        case let .tlsHandshakeFailed(detail):
            return "TLS handshake failed: \(detail)"
        case let .tlsIO(detail):
            return "TLS I/O error: \(detail)"
        case .tlsNotAvailable:
            return "server does not support TLS but it was required"
        case .clientShutdown:
            return "the connection pool has been shut down"
        case let .tooManyParameters(count):
            return "too many parameters: \(count) (PostgreSQL allows at most 65535 per statement)"
        case .preparedStatementConnectionMismatch:
            return "prepared statement belongs to a different connection"
        case let .copyMismatch(detail):
            return "COPY mismatch: \(detail)"
        case .timedOut:
            return "operation timed out"
        }
    }
}

extension PerunError {
    /// The structured server error, when this is a `.server` error — so callers can
    /// reach `sqlState` / `constraintName` without unwrapping the case by hand.
    public var serverError: PostgresServerError? {
        if case let .server(error) = self { return error }
        return nil
    }

    /// Whether this error may have left the connection's wire out of sync, so a
    /// pooled connection that hit it must be discarded rather than reused.
    var mayHaveDesynchronizedWire: Bool {
        switch self {
        case .connectionClosed, .ioError, .connectionFailed, .protocolViolation, .tlsHandshakeFailed,
             .tlsIO, .tlsNotAvailable, .authenticationFailed, .unsupportedAuthentication:
            return true
        case .server, .unexpectedNull, .columnNotFound, .decodingFailed, .tooManyParameters,
             .clientShutdown, .preparedStatementConnectionMismatch, .copyMismatch, .timedOut:
            return false
        }
    }
}
