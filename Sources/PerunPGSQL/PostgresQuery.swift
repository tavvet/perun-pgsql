/// A SQL statement and its bound parameters — one item in a heterogeneous pipelined
/// batch (`PostgresConnection.pipeline([...])`). Formats are per-query, so a single
/// batch can mix text and binary commands.
public struct PostgresQuery: Sendable {
    public var sql: String
    public var parameters: [(any PostgresEncodable)?]
    public var parameterFormat: PostgresFormat
    public var resultFormat: PostgresFormat

    public init(_ sql: String,
                _ parameters: [(any PostgresEncodable)?] = [],
                parameterFormat: PostgresFormat = .text,
                resultFormat: PostgresFormat = .text) {
        self.sql = sql
        self.parameters = parameters
        self.parameterFormat = parameterFormat
        self.resultFormat = resultFormat
    }
}
