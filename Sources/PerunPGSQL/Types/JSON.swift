// A JSON document bound for a `json` or `jsonb` parameter, or decoded from one.
//
// The driver treats JSON as opaque UTF-8 text: it neither parses nor validates the
// contents. `PostgresJSON` carries the raw JSON string together with which
// PostgreSQL type it is — `jsonb` (the default; binary, normalized by the server)
// or `json` (stored verbatim). Mapping JSON to and from Swift models is a job for a
// higher layer, so this stays a thin, ORM-agnostic wrapper.

public struct PostgresJSON: Sendable, Equatable {
    /// The raw JSON text.
    public var text: String
    /// `true` for `jsonb` (OID 3802); `false` for `json` (OID 114).
    public var jsonb: Bool

    public init(_ text: String, jsonb: Bool = true) {
        self.text = text
        self.jsonb = jsonb
    }
}

extension PostgresJSON: PostgresEncodable {
    public var postgresText: String? { text }
    public var postgresTypeOID: Int32 { jsonb ? PostgresOID.jsonb : PostgresOID.json }
    public func postgresBinary() -> [UInt8]? {
        // `json` binary is the text as-is; `jsonb` binary is a 1-byte version
        // header (0x01) followed by the text.
        var bytes = Array(text.utf8)
        if jsonb { bytes.insert(1, at: 0) }
        return bytes
    }
}

extension PostgresJSON: PostgresDecodable {
    public static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> PostgresJSON {
        let isJSONB = oid == PostgresOID.jsonb
        if isJSONB, format == .binary {
            guard bytes.first == 1 else {
                throw postgresDecodeError("PostgresJSON", oid: oid, format: format, bytes)
            }
            return PostgresJSON(String(decoding: bytes.dropFirst(), as: UTF8.self), jsonb: true)
        }
        return PostgresJSON(utf8String(bytes), jsonb: isJSONB)
    }
}
