/// A structured error reported by the PostgreSQL server (an `ErrorResponse`).
///
/// The fields are the raw single-byte-tagged strings from the protocol; the
/// computed properties expose the common ones. See the PostgreSQL protocol
/// docs, "Error and Notice Message Fields".
public struct PostgresServerError: Error, Sendable, CustomStringConvertible {
    /// Raw fields keyed by their single-byte type code (e.g. `S`, `C`, `M`).
    public let fields: [UInt8: String]

    public init(fields: [UInt8: String]) {
        self.fields = fields
    }

    private func field(_ char: Character) -> String? {
        fields[char.asciiValue!]
    }

    /// Severity: `ERROR`, `FATAL`, `PANIC`, `WARNING`, …
    public var severity: String? { field("S") }
    /// SQLSTATE code, e.g. `28P01` (invalid password), `42P01` (undefined table).
    public var sqlState: String? { field("C") }
    /// Primary human-readable message.
    public var message: String? { field("M") }
    /// Optional secondary detail.
    public var detail: String? { field("D") }
    /// Optional hint on how to fix it.
    public var hint: String? { field("H") }

    public var description: String {
        let sev = severity ?? "ERROR"
        let code = sqlState.map { " [\($0)]" } ?? ""
        var text = "\(sev)\(code): \(message ?? "(no message)")"
        if let detail { text += " — \(detail)" }
        if let hint { text += " (hint: \(hint))" }
        return text
    }
}

/// Everything the driver itself can throw.
public enum PerunError: Error, CustomStringConvertible, Sendable {
    /// The server sent something that violates the wire protocol, or a message
    /// was truncated.
    case protocolViolation(String)
    /// The connection was closed unexpectedly (EOF mid-message).
    case connectionClosed
    /// A structured error from the server.
    case server(PostgresServerError)
    /// The server asked for an authentication method we do not implement yet.
    case unsupportedAuthentication(String)
    /// Authentication was attempted but failed on our side (e.g. missing
    /// password, bad SASL exchange).
    case authenticationFailed(String)
    /// A non-optional value was requested from a column that held SQL NULL.
    case unexpectedNull(column: String)
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

    public var description: String {
        switch self {
        case let .protocolViolation(detail):
            return "protocol violation: \(detail)"
        case .connectionClosed:
            return "connection closed by server"
        case let .server(error):
            return error.description
        case let .unsupportedAuthentication(detail):
            return "unsupported authentication method: \(detail)"
        case let .authenticationFailed(detail):
            return "authentication failed: \(detail)"
        case let .unexpectedNull(column):
            return "unexpected NULL decoding column \"\(column)\""
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
        }
    }
}
