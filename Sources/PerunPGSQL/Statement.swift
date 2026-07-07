/// A server-side prepared statement: SQL that has been `Parse`d once and can be
/// `execute`d many times with different parameters.
///
/// Obtain one from `PostgresConnection.prepare(_:)` and run it with
/// `PostgresConnection.execute(_:_:)`.
public struct PreparedStatement: Sendable {
    /// The server-side statement name.
    public let name: String
    /// OIDs of the `$1…$n` parameters, as reported by the server.
    public let parameterTypeOIDs: [Int32]
    /// Result columns, learned when the statement was described at prepare time.
    public let columns: [ColumnMetadata]
}
