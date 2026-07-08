// Decoding PostgreSQL array result columns into Swift arrays.
//
// Arrays can't ride the `PostgresDecodable` protocol (an `Array` conformance would clash
// with the `[UInt8]` bytea decoder), so decoding is exposed as `decodeArray` on cells and
// rows. Both wire formats carry the full (possibly multi-dimensional) shape; this parses
// each into flat, row-major elements plus a dimension list, then the typed entry points
// reshape and decode. One- and two-dimensional arrays are supported.

/// A parsed array: the element type OID, the length of each dimension, and every element's
/// raw bytes in row-major order (`nil` for a NULL element).
func parsePostgresArray(_ bytes: [UInt8], arrayOID: Int32,
                        format: PostgresFormat) throws -> (elementOID: Int32, dimensions: [Int], elements: [[UInt8]?]) {
    switch format {
    case .binary: return try parseBinaryArray(bytes, arrayOID: arrayOID)
    case .text:   return try parseTextArray(bytes, arrayOID: arrayOID)
    }
}

/// Binary array: `int32 ndim, int32 flags, int32 element-OID`, then per dimension
/// `int32 length, int32 lower-bound`, then each element as `int32 length` (`-1` = NULL)
/// followed by its bytes, in row-major order.
private func parseBinaryArray(_ bytes: [UInt8],
                              arrayOID: Int32) throws -> (Int32, [Int], [[UInt8]?]) {
    func fail() -> PerunError { postgresDecodeError("array", oid: arrayOID, format: .binary, bytes) }
    var reader = ByteReader(bytes)
    let ndim = Int(try reader.readInt32())
    _ = try reader.readInt32()                      // flags (bit 0 = has nulls)
    let elementOID = try reader.readInt32()
    guard ndim >= 0, ndim <= 6 else { throw fail() }

    var dimensions: [Int] = []
    dimensions.reserveCapacity(ndim)
    for _ in 0 ..< ndim {
        let length = Int(try reader.readInt32())
        _ = try reader.readInt32()                  // lower bound (ignored)
        guard length >= 0 else { throw fail() }
        dimensions.append(length)
    }

    let total = ndim == 0 ? 0 : dimensions.reduce(1, *)
    var elements: [[UInt8]?] = []
    elements.reserveCapacity(total)
    for _ in 0 ..< total {
        let length = Int(try reader.readInt32())
        elements.append(length < 0 ? nil : try reader.readBytes(length))
    }
    return (elementOID, dimensions, elements)
}

/// Text array: `{1,2,3}`, `{{1,2},{3,4}}`, `{}`, `{a,"b,c",NULL}`. Elements are quoted (with
/// `"`/`\` escaped) when they need it; an unquoted `NULL` is a SQL NULL.
private func parseTextArray(_ bytes: [UInt8],
                            arrayOID: Int32) throws -> (Int32, [Int], [[UInt8]?]) {
    let elementOID = elementTypeOID(forArray: arrayOID)
    var index = 0
    func fail() -> PerunError { postgresDecodeError("array", oid: arrayOID, format: .text, bytes) }
    func skipSpaces() { while index < bytes.count, bytes[index] == 0x20 { index += 1 } }

    func parseElement() throws -> [UInt8]? {
        if index < bytes.count, bytes[index] == 0x22 {          // '"' — quoted, never NULL
            index += 1
            var out: [UInt8] = []
            while index < bytes.count, bytes[index] != 0x22 {
                if bytes[index] == 0x5c {                        // '\' — take the next byte literally
                    index += 1
                    guard index < bytes.count else { throw fail() }
                }
                out.append(bytes[index]); index += 1
            }
            guard index < bytes.count else { throw fail() }
            index += 1                                           // closing '"'
            return out
        }
        let start = index
        while index < bytes.count, bytes[index] != 0x2c, bytes[index] != 0x7d { index += 1 }   // until ',' or '}'
        let raw = Array(bytes[start ..< index])
        if raw.count == 4,                                       // unquoted NULL (case-insensitive)
           raw[0] | 0x20 == 0x6e, raw[1] | 0x20 == 0x75, raw[2] | 0x20 == 0x6c, raw[3] | 0x20 == 0x6c {
            return nil
        }
        return raw
    }

    indirect enum Node { case leaf([UInt8]?); case level([Node]) }
    func parseLevel() throws -> [Node] {
        guard index < bytes.count, bytes[index] == 0x7b else { throw fail() }   // '{'
        index += 1
        var nodes: [Node] = []
        skipSpaces()
        if index < bytes.count, bytes[index] == 0x7d { index += 1; return nodes }   // '}' — empty
        while true {
            skipSpaces()
            nodes.append(index < bytes.count && bytes[index] == 0x7b ? .level(try parseLevel())
                                                                     : .leaf(try parseElement()))
            skipSpaces()
            guard index < bytes.count else { throw fail() }
            if bytes[index] == 0x2c { index += 1; continue }     // ','
            if bytes[index] == 0x7d { index += 1; break }        // '}'
            throw fail()
        }
        return nodes
    }

    skipSpaces()
    let root = try parseLevel()

    func dimensions(_ nodes: [Node]) -> [Int] {
        guard !nodes.isEmpty else { return [] }
        var dims = [nodes.count]
        if case let .level(sub) = nodes[0] { dims += dimensions(sub) }
        return dims
    }
    var elements: [[UInt8]?] = []
    func flatten(_ nodes: [Node]) {
        for node in nodes {
            switch node {
            case let .leaf(value): elements.append(value)
            case let .level(sub): flatten(sub)
            }
        }
    }
    flatten(root)
    return (elementOID, dimensions(root), elements)
}

/// Map an array type OID to its element type OID (the inverse of `PostgresArray`'s hint).
/// `0` for unknown — fine for text elements, whose decoders ignore the OID.
func elementTypeOID(forArray oid: Int32) -> Int32 {
    switch oid {
    case 1000: return PostgresOID.bool
    case 1001: return PostgresOID.bytea
    case 1005: return PostgresOID.int2
    case 1007: return PostgresOID.int4
    case 1016: return PostgresOID.int8
    case 1009: return PostgresOID.text
    case 1014: return PostgresOID.bpchar
    case 1015: return PostgresOID.varchar
    case 199:  return PostgresOID.json
    case 1021: return PostgresOID.float4
    case 1022: return PostgresOID.float8
    case 1182: return PostgresOID.date
    case 1115: return PostgresOID.timestamp
    case 1185: return PostgresOID.timestamptz
    case 1231: return PostgresOID.numeric
    case 2951: return PostgresOID.uuid
    case 3807: return PostgresOID.jsonb
    default:   return 0
    }
}

// MARK: - Typed decoding on a cell

public extension PostgresCell {
    /// Decode a one-dimensional array into `[T]`. Throws on a NULL element (use the `[T?]`
    /// overload) or a higher-dimensional array.
    func decodeArray<T: PostgresDecodable>(of type: T.Type = T.self) throws -> [T] {
        let (elements, oid, format) = try flatArray(maxDimensions: 1)
        return try elements.map { try decodeElement($0, oid: oid, format: format) }
    }

    /// Decode a one-dimensional array into `[T?]`, mapping SQL NULL elements to `nil`.
    func decodeArray<T: PostgresDecodable>(of type: T.Type = T.self) throws -> [T?] {
        let (elements, oid, format) = try flatArray(maxDimensions: 1)
        return try elements.map { bytes in try bytes.map { try T.decode($0, oid: oid, format: format) } }
    }

    /// Decode a two-dimensional array into `[[T]]`. Throws on a NULL element.
    func decodeArray<T: PostgresDecodable>(of type: T.Type = T.self) throws -> [[T]] {
        let (rows, oid, format) = try rowsArray()
        return try rows.map { try $0.map { try decodeElement($0, oid: oid, format: format) } }
    }

    /// Decode a two-dimensional array into `[[T?]]`, mapping SQL NULL elements to `nil`.
    func decodeArray<T: PostgresDecodable>(of type: T.Type = T.self) throws -> [[T?]] {
        let (rows, oid, format) = try rowsArray()
        return try rows.map { row in try row.map { bytes in try bytes.map { try T.decode($0, oid: oid, format: format) } } }
    }

    private func decodeElement<T: PostgresDecodable>(_ bytes: [UInt8]?, oid: Int32, format: PostgresFormat) throws -> T {
        guard let bytes else { throw PerunError.unexpectedNull(column: column.name) }
        return try T.decode(bytes, oid: oid, format: format)
    }

    private func flatArray(maxDimensions: Int) throws -> (elements: [[UInt8]?], oid: Int32, format: PostgresFormat) {
        guard let bytes else { throw PerunError.unexpectedNull(column: column.name) }
        let format: PostgresFormat = column.formatCode == 1 ? .binary : .text
        let parsed = try parsePostgresArray(bytes, arrayOID: column.dataTypeOID, format: format)
        guard parsed.dimensions.count <= maxDimensions else {
            throw PerunError.decodingFailed(type: "array", oid: column.dataTypeOID,
                                            format: format == .binary ? "binary" : "text",
                                            reason: "\(parsed.dimensions.count)-dimensional array, expected \(maxDimensions)")
        }
        return (parsed.elements, parsed.elementOID, format)
    }

    private func rowsArray() throws -> (rows: [[[UInt8]?]], oid: Int32, format: PostgresFormat) {
        guard let bytes else { throw PerunError.unexpectedNull(column: column.name) }
        let format: PostgresFormat = column.formatCode == 1 ? .binary : .text
        let parsed = try parsePostgresArray(bytes, arrayOID: column.dataTypeOID, format: format)
        if parsed.elements.isEmpty { return ([], parsed.elementOID, format) }        // {} → []
        guard parsed.dimensions.count == 2 else {
            throw PerunError.decodingFailed(type: "array", oid: column.dataTypeOID,
                                            format: format == .binary ? "binary" : "text",
                                            reason: "\(parsed.dimensions.count)-dimensional array, expected 2")
        }
        let width = parsed.dimensions[1]
        var rows: [[[UInt8]?]] = []
        var i = 0
        while i < parsed.elements.count {
            rows.append(Array(parsed.elements[i ..< min(i + width, parsed.elements.count)]))
            i += width
        }
        return (rows, parsed.elementOID, format)
    }
}

// MARK: - Typed decoding on a row

public extension PostgresRow {
    func decodeArray<T: PostgresDecodable>(_ name: String, of type: T.Type = T.self) throws -> [T] {
        try cell(name).decodeArray(of: type)
    }

    func decodeArray<T: PostgresDecodable>(_ name: String, of type: T.Type = T.self) throws -> [T?] {
        try cell(name).decodeArray(of: type)
    }

    func decodeArray<T: PostgresDecodable>(_ name: String, of type: T.Type = T.self) throws -> [[T]] {
        try cell(name).decodeArray(of: type)
    }

    func decodeArray<T: PostgresDecodable>(_ name: String, of type: T.Type = T.self) throws -> [[T?]] {
        try cell(name).decodeArray(of: type)
    }
}
