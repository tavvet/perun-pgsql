// A one-dimensional PostgreSQL array bound as a parameter — `int8[]`, `text[]`,
// `uuid[]`, and so on. Elements are any `PostgresEncodable`; a `nil` element is SQL
// NULL. It is sent as text (`{1,2,3}`) by default, or in binary when the caller asks
// for binary and every element has a binary form.
//
// This is the parameter (encode) direction only, and a single dimension: decoding
// arrays back into Swift arrays, and multi-dimensional arrays, are separate concerns
// a higher layer can add without the driver dictating their shape.

public struct PostgresArray: PostgresEncodable {
    /// The elements, each `nil` for SQL NULL.
    public var elements: [PostgresEncodable?]
    /// OID of the *element* type (e.g. `PostgresOID.int8`). Drives the binary header
    /// and the array-type hint; `0` means "let the server infer" and forces text.
    public var elementTypeOID: Int32

    public init(_ elements: [PostgresEncodable?], elementTypeOID: Int32) {
        self.elements = elements
        self.elementTypeOID = elementTypeOID
    }

    /// Non-null elements; the element type OID is taken from the first element.
    public init<Element: PostgresEncodable>(_ elements: [Element]) {
        self.init(elements.map { $0 as PostgresEncodable? },
                  elementTypeOID: elements.first?.postgresTypeOID ?? 0)
    }

    /// Elements that may be SQL NULL; the OID is taken from the first non-null element.
    public init<Element: PostgresEncodable>(_ elements: [Element?]) {
        self.init(elements.map { $0.map { $0 as PostgresEncodable } },
                  elementTypeOID: elements.compactMap { $0 }.first?.postgresTypeOID ?? 0)
    }

    public var postgresTypeOID: Int32 { arrayTypeOID(forElement: elementTypeOID) }

    /// `{elem,elem,NULL,…}`. Every non-null element is double-quoted (and `"`/`\`
    /// escaped), so numbers, strings with commas, `\x…` bytea and JSON all carry
    /// literally; a nil element is the unquoted word `NULL`.
    public var postgresText: String? {
        var out = "{"
        for (index, element) in elements.enumerated() {
            if index > 0 { out += "," }
            if let text = element?.postgresText {
                out += quoteArrayElement(text)
            } else {
                out += "NULL"
            }
        }
        out += "}"
        return out
    }

    /// PostgreSQL array binary form: `int32 ndim, int32 flags, int32 element OID`,
    /// then per dimension `int32 length, int32 lower-bound`, then each element as
    /// `int32 length` (`-1` for NULL) followed by its bytes. Returns nil — falling
    /// back to text — when the element type is unknown or an element has no binary form.
    public func postgresBinary() -> [UInt8]? {
        guard elementTypeOID != 0 else { return nil }
        var body = [UInt8]()
        var hasNulls = false
        for element in elements {
            guard let element else {
                hasNulls = true
                body += bigEndianBytes(Int32(-1))
                continue
            }
            guard let bytes = element.postgresBinary() else { return nil }
            body += bigEndianBytes(Int32(bytes.count))
            body += bytes
        }

        var out = [UInt8]()
        out += bigEndianBytes(Int32(1))                    // ndim (one dimension)
        out += bigEndianBytes(Int32(hasNulls ? 1 : 0))     // flags: bit 0 = has nulls
        out += bigEndianBytes(elementTypeOID)              // element type OID
        out += bigEndianBytes(Int32(elements.count))       // dimension length
        out += bigEndianBytes(Int32(1))                    // lower bound (PostgreSQL default)
        out += body
        return out
    }
}

/// Double-quote an array element, escaping `"` and `\`. Inside quotes every other
/// character — commas, braces, whitespace — is literal, so this is enough.
private func quoteArrayElement(_ text: String) -> String {
    var out = "\""
    for character in text {
        if character == "\"" || character == "\\" { out.append("\\") }
        out.append(character)
    }
    out.append("\"")
    return out
}

/// Map an element type OID to its array type OID (`pg_type.typarray`) for the `Parse`
/// hint. `0` when unknown — the server then infers the array type from a cast or the
/// target column.
private func arrayTypeOID(forElement oid: Int32) -> Int32 {
    switch oid {
    case PostgresOID.bool:        return 1000
    case PostgresOID.bytea:       return 1001
    case PostgresOID.int2:        return 1005
    case PostgresOID.int4:        return 1007
    case PostgresOID.int8:        return 1016
    case PostgresOID.text:        return 1009
    case PostgresOID.json:        return 199
    case PostgresOID.float4:      return 1021
    case PostgresOID.float8:      return 1022
    case PostgresOID.date:        return 1182
    case PostgresOID.timestamp:   return 1115
    case PostgresOID.timestamptz: return 1185
    case PostgresOID.numeric:     return 1231
    case PostgresOID.uuid:        return 2951
    case PostgresOID.jsonb:       return 3807
    default:                      return 0
    }
}
