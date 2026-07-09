import PerunPGSQL

/// A user-defined type stored as text — conforming to both PostgresDecodable and PostgresEncodable
/// — round-tripped through the server.
enum Color: String, PostgresDecodable, PostgresEncodable {
    case red, green, blue

    static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> Color {
        let text = String(decoding: bytes, as: UTF8.self)
        guard let color = Color(rawValue: text) else {
            throw PerunError.decodingFailed(type: "Color", oid: oid, format: "\(format)", reason: text)
        }
        return color
    }

    var postgresText: String? { rawValue }
    var postgresTypeOID: Int32 { PostgresOID.text }
}

func runCustomType() async throws {
    let connection = try await PostgresConnection.connect(exampleConfiguration())
    defer { Task { try? await connection.close() } }

    let roundTripped: Color = try await connection.query("SELECT $1::text AS c", [Color.green])
        .rows[0].decode("c")
    print("round-tripped color: \(roundTripped)")
}
