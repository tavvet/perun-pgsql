import PerunPGSQL

/// Provoke a server error, branch on its typed `SQLState`, and show that the connection is still
/// in sync (reusable) immediately afterwards — a server error never desynchronises the wire.
func runErrorHandling() async throws {
    let connection = try await PostgresConnection.connect(exampleConfiguration())
    defer { Task { try? await connection.close() } }

    _ = try await connection.query("CREATE TEMP TABLE accounts (email text UNIQUE)")
    _ = try await connection.query("INSERT INTO accounts VALUES ('a@example.com')")

    // The duplicate insert fails on the server. Branch on the typed SQLState, never on the message.
    do {
        _ = try await connection.query("INSERT INTO accounts VALUES ('a@example.com')")
    } catch let error as PerunError where error.serverError?.sqlState == .uniqueViolation {
        print("email already taken (constraint \(error.serverError?.constraintName ?? "?"))")
    }

    // The wire drained to ReadyForQuery before the error surfaced, so the connection is reusable
    // right away — no reconnect needed.
    let count = try await connection.query("SELECT count(*)::int AS c FROM accounts")
        .rows[0].decode("c", as: Int.self)
    print("rows still readable: \(count)")
}
