import PerunPGSQL

/// A transfer inside a transaction: both updates commit together, or neither does.
func runTransactions() async throws {
    let connection = try await PostgresConnection.connect(exampleConfiguration())
    defer { Task { try? await connection.close() } }

    _ = try await connection.query("CREATE TEMP TABLE accounts (id int PRIMARY KEY, balance int)")
    _ = try await connection.query("INSERT INTO accounts VALUES (1, 100), (2, 0)")

    try await connection.withTransaction { tx in
        try await tx.query("UPDATE accounts SET balance = balance - $1 WHERE id = $2", [40, 1])
        try await tx.query("UPDATE accounts SET balance = balance + $1 WHERE id = $2", [40, 2])
    }

    for row in try await connection.query("SELECT id, balance FROM accounts ORDER BY id").rows {
        let id = try row.decode("id", as: Int.self)
        let balance = try row.decode("balance", as: Int.self)
        print("account \(id): \(balance)")
    }
}
