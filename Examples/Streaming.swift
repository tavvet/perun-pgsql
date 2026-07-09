import PerunPGSQL

/// Stream a large result lazily, summing it a chunk at a time instead of buffering all rows.
func runStreaming() async throws {
    let connection = try await PostgresConnection.connect(exampleConfiguration())
    defer { Task { try? await connection.close() } }

    var sum = 0
    for try await row in try await connection.queryStream(
        "SELECT g FROM generate_series(1, 1000) g", chunkSize: 100) {
        sum += try row.decode("g", as: Int.self)
    }
    print("streamed sum of 1...1000: \(sum)")   // 500500
}
