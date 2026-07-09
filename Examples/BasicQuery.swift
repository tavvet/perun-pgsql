import PerunPGSQL

/// Connect, run one parameterised query, decode a column, close.
func runBasicQuery() async throws {
    let connection = try await PostgresConnection.connect(exampleConfiguration())
    defer { Task { try? await connection.close() } }

    let rows = try await connection.query("SELECT $1::int * 2 AS doubled", [21]).rows
    let doubled = try rows[0].decode("doubled", as: Int.self)
    print("doubled = \(doubled)")
}
