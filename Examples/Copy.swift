import PerunPGSQL

/// Bulk-load rows with COPY FROM STDIN, then stream them back out with COPY TO STDOUT.
func runCopy() async throws {
    let connection = try await PostgresConnection.connect(exampleConfiguration())
    defer { Task { try? await connection.close() } }

    _ = try await connection.query("CREATE TEMP TABLE events (id int, name text)")

    try await connection.copyIn("COPY events FROM STDIN") { writer in
        try await writer.write("1\talpha\n")
        try await writer.write("2\tbeta\n")
    }

    var dump = [UInt8]()
    for try await chunk in try await connection.copyOut("COPY events TO STDOUT") {
        dump.append(contentsOf: chunk)
    }
    print("copied out:")
    print(String(decoding: dump, as: UTF8.self), terminator: "")
}
