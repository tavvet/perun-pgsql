// A PostgreSQL array bound as a parameter — `int8[]`, `text[]`, `uuid[]`, and so on,
// in one or more dimensions. Elements are any `PostgresEncodable`; a `nil` element is
// SQL NULL. It is sent as text (`{1,2,3}`, `{{1,2},{3,4}}`) by default, or in binary
// when the caller asks for binary and every element has a binary form.
//
// The shape is a flat, row-major element list plus a `dimensions` list — the same model
// the array decoder produces. One- and two-dimensional arrays have ergonomic
// initializers (`[Element]`, `[[Element]]`); higher dimensions go through the explicit
// `init(dimensions:elements:elementTypeOID:)`.

public struct PostgresArray: PostgresEncodable {
    /// The elements in row-major order, each `nil` for SQL NULL.
    public var elements: [PostgresEncodable?]
    /// The length of each dimension, outermost first; their product is `elements.count`.
    /// A single entry is a one-dimensional array.
    public var dimensions: [Int]
    /// OID of the *element* type (e.g. `PostgresOID.int8`). Drives the binary header
    /// and the array-type hint; `0` means "let the server infer" and forces text.
    public var elementTypeOID: Int32

    /// A multi-dimensional array from a flat, row-major element list and an explicit
    /// shape. `dimensions` must multiply to `elements.count`.
    public init(dimensions: [Int], elements: [PostgresEncodable?], elementTypeOID: Int32) {
        precondition(dimensions.reduce(1, *) == elements.count,
                     "PostgresArray dimensions \(dimensions) don't match \(elements.count) elements")
        self.dimensions = dimensions
        self.elements = elements
        self.elementTypeOID = elementTypeOID
    }

    /// A one-dimensional array from a flat element list.
    public init(_ elements: [PostgresEncodable?], elementTypeOID: Int32) {
        self.init(dimensions: [elements.count], elements: elements, elementTypeOID: elementTypeOID)
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

    /// A two-dimensional array from rows of non-null elements. Rows must be rectangular
    /// (all the same length); the element type OID is taken from the first element.
    public init<Element: PostgresEncodable>(_ rows: [[Element]]) {
        let width = rows.first?.count ?? 0
        precondition(rows.allSatisfy { $0.count == width }, "PostgresArray rows must be rectangular")
        self.init(dimensions: [rows.count, width],
                  elements: rows.flatMap { $0.map { $0 as PostgresEncodable? } },
                  elementTypeOID: rows.first?.first?.postgresTypeOID ?? 0)
    }

    /// A two-dimensional array whose elements may be SQL NULL; rows must be rectangular.
    /// The element type OID is taken from the first non-null element.
    public init<Element: PostgresEncodable>(_ rows: [[Element?]]) {
        let width = rows.first?.count ?? 0
        precondition(rows.allSatisfy { $0.count == width }, "PostgresArray rows must be rectangular")
        self.init(dimensions: [rows.count, width],
                  elements: rows.flatMap { $0.map { $0.map { $0 as PostgresEncodable } } },
                  elementTypeOID: rows.compactMap { $0.compactMap { $0 }.first }.first?.postgresTypeOID ?? 0)
    }

    public var postgresTypeOID: Int32 { arrayTypeOID(forElement: elementTypeOID) }

    /// Nested braces following `dimensions`: `{1,2,3}`, `{{1,2},{3,4}}`. Every non-null
    /// element is double-quoted (and `"`/`\` escaped), so numbers, strings with commas,
    /// `\x…` bytea and JSON all carry literally; a nil element is the unquoted word `NULL`.
    public var postgresText: String? {
        guard !dimensions.isEmpty else { return "{}" }
        var offset = 0
        func render(_ dimension: Int) -> String {
            var out = "{"
            for position in 0 ..< dimensions[dimension] {
                if position > 0 { out += "," }
                if dimension == dimensions.count - 1 {
                    if let text = elements[offset]?.postgresText {
                        out += quoteArrayElement(text)
                    } else {
                        out += "NULL"
                    }
                    offset += 1
                } else {
                    out += render(dimension + 1)
                }
            }
            out += "}"
            return out
        }
        return render(0)
    }

    /// PostgreSQL array binary form: `int32 ndim, int32 flags, int32 element OID`, then
    /// per dimension `int32 length, int32 lower-bound`, then each element as `int32
    /// length` (`-1` for NULL) followed by its bytes, in row-major order. Returns nil —
    /// falling back to text — when the element type is unknown or an element has no
    /// binary form.
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
        out += bigEndianBytes(Int32(dimensions.count))     // ndim
        out += bigEndianBytes(Int32(hasNulls ? 1 : 0))     // flags: bit 0 = has nulls
        out += bigEndianBytes(elementTypeOID)              // element type OID
        for length in dimensions {
            out += bigEndianBytes(Int32(length))           // dimension length
            out += bigEndianBytes(Int32(1))                // lower bound (PostgreSQL default)
        }
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
