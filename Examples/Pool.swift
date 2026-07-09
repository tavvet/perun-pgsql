import PerunPGSQL

/// Fan out concurrent queries over a pool; it opens at most `maxConnections` connections.
func runPool() async throws {
    let pool = PostgresClient(configuration: exampleConfiguration(), maxConnections: 4)
    defer { Task { await pool.shutdown() } }

    let total = try await withThrowingTaskGroup(of: Int.self) { group in
        for n in 1 ... 8 {
            group.addTask {
                try await pool.query("SELECT $1::int AS n", [n]).rows[0].decode("n", as: Int.self)
            }
        }
        var sum = 0
        for try await value in group { sum += value }
        return sum
    }
    print("sum of 1...8 across the pool: \(total)")   // 36
}
