// Decoding PostgreSQL array result columns into Swift arrays.
//
// Arrays can't ride the `PostgresDecodable` protocol (an `Array` conformance would clash
// with the `[UInt8]` bytea decoder), so decoding is exposed as `decodeArray` on cells and
// rows. Both wire formats carry the full (possibly multi-dimensional) shape; this parses
// each into flat, row-major elements plus a dimension list, then the typed entry points
// reshape and decode into `[T]`, `[[T]]`, `[[[T]]]` and deeper.

import Foundation

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
    // Optional dimension decoration, emitted when a lower bound isn't 1: `[2:4]=` (or
    // `[1:2][1:3]=` for higher dimensions). We take the shape from the braces, so skip
    // past the bounds to the `=`.
    if index < bytes.count, bytes[index] == 0x5b {                  // '['
        while index < bytes.count, bytes[index] == 0x5b {           // one [lower:upper] per dimension
            while index < bytes.count, bytes[index] != 0x5d { index += 1 }
            guard index < bytes.count else { throw fail() }
            index += 1                                              // ']'
        }
        guard index < bytes.count, bytes[index] == 0x3d else { throw fail() }   // '='
        index += 1
    }
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

// MARK: - Nested array reshaping

/// A Swift type a parsed array reshapes into: a scalar leaf (`Int`, `String`, …), an
/// optional leaf (`Int?`, where SQL NULL becomes `nil`), or a nested `Array` of another
/// such type. This is what lets `decodeArray` return `[T]`, `[[T]]`, `[[[T]]]` and deeper,
/// with the nesting depth checked against the array's dimensions.
///
/// `_decodeArrayLevel` is an implementation detail — call `decodeArray` on a cell or row.
public protocol PostgresArrayDecodable {
    /// The scalar element type at the bottom of the nesting (drives the `of:` hint).
    associatedtype ArrayScalar: PostgresDecodable
    static func _decodeArrayLevel(_ dimensions: ArraySlice<Int>, from elements: [[UInt8]?],
                                  at index: inout Int, oid: Int32, format: PostgresFormat,
                                  columnName: String) throws -> Self
}

private func arrayShapeError(_ oid: Int32, _ format: PostgresFormat, _ reason: String) -> PerunError {
    .decodingFailed(type: "array", oid: oid, format: format == .binary ? "binary" : "text", reason: reason)
}

/// A nesting level: consume one dimension, decoding `dimensions.first` children.
extension Array: PostgresArrayDecodable where Element: PostgresArrayDecodable {
    public typealias ArrayScalar = Element.ArrayScalar
    public static func _decodeArrayLevel(_ dimensions: ArraySlice<Int>, from elements: [[UInt8]?],
                                         at index: inout Int, oid: Int32, format: PostgresFormat,
                                         columnName: String) throws -> [Element] {
        guard let count = dimensions.first else {
            throw arrayShapeError(oid, format, "array has fewer dimensions than the requested nesting")
        }
        let rest = dimensions.dropFirst()
        var out: [Element] = []
        out.reserveCapacity(count)
        for _ in 0 ..< count {
            out.append(try Element._decodeArrayLevel(rest, from: elements, at: &index,
                                                     oid: oid, format: format, columnName: columnName))
        }
        return out
    }
}

/// A nullable leaf: a SQL NULL element becomes `nil`.
extension Optional: PostgresArrayDecodable where Wrapped: PostgresDecodable {
    public typealias ArrayScalar = Wrapped
    public static func _decodeArrayLevel(_ dimensions: ArraySlice<Int>, from elements: [[UInt8]?],
                                         at index: inout Int, oid: Int32, format: PostgresFormat,
                                         columnName: String) throws -> Wrapped? {
        guard dimensions.isEmpty else {
            throw arrayShapeError(oid, format, "array has more dimensions than the requested nesting")
        }
        guard index < elements.count else { throw arrayShapeError(oid, format, "array element count mismatch") }
        defer { index += 1 }
        guard let bytes = elements[index] else { return nil }
        return try Wrapped.decode(bytes, oid: oid, format: format)
    }
}

/// A non-null leaf: any `PostgresDecodable` scalar. A SQL NULL element throws.
public extension PostgresArrayDecodable where Self: PostgresDecodable, ArrayScalar == Self {
    static func _decodeArrayLevel(_ dimensions: ArraySlice<Int>, from elements: [[UInt8]?],
                                  at index: inout Int, oid: Int32, format: PostgresFormat,
                                  columnName: String) throws -> Self {
        guard dimensions.isEmpty else {
            throw arrayShapeError(oid, format, "array has more dimensions than the requested nesting")
        }
        guard index < elements.count else { throw arrayShapeError(oid, format, "array element count mismatch") }
        defer { index += 1 }
        guard let bytes = elements[index] else { throw PerunError.unexpectedNull(column: columnName) }
        return try Self.decode(bytes, oid: oid, format: format)
    }
}

// Scalar leaves — every built-in `PostgresDecodable` scalar. (`[UInt8]` bytea is itself an
// `Array`, so it can't also be a leaf; decode a `bytea[]` column into `[Data]` instead.)
extension Bool: PostgresArrayDecodable { public typealias ArrayScalar = Bool }
extension Int16: PostgresArrayDecodable { public typealias ArrayScalar = Int16 }
extension Int32: PostgresArrayDecodable { public typealias ArrayScalar = Int32 }
extension Int64: PostgresArrayDecodable { public typealias ArrayScalar = Int64 }
extension Int: PostgresArrayDecodable { public typealias ArrayScalar = Int }
extension Float: PostgresArrayDecodable { public typealias ArrayScalar = Float }
extension Double: PostgresArrayDecodable { public typealias ArrayScalar = Double }
extension String: PostgresArrayDecodable { public typealias ArrayScalar = String }
extension Data: PostgresArrayDecodable { public typealias ArrayScalar = Data }
extension UUID: PostgresArrayDecodable { public typealias ArrayScalar = UUID }
extension Date: PostgresArrayDecodable { public typealias ArrayScalar = Date }
extension Decimal: PostgresArrayDecodable { public typealias ArrayScalar = Decimal }
extension PostgresJSON: PostgresArrayDecodable { public typealias ArrayScalar = PostgresJSON }

// MARK: - Typed decoding on a cell and row

public extension PostgresCell {
    /// Decode an array column into a nested Swift array — `[T]`, `[T?]`, `[[T]]`, `[[[T]]]`
    /// and deeper — of any `PostgresDecodable` scalar `T`. The nesting depth must match the
    /// array's dimensionality (a mismatch throws); an empty array is `[]`. Use an optional
    /// scalar (`[T?]`, `[[T?]]`, …) for arrays that contain SQL NULLs.
    func decodeArray<Element: PostgresArrayDecodable>(
        of scalar: Element.ArrayScalar.Type = Element.ArrayScalar.self) throws -> [Element] {
        guard let bytes else { throw PerunError.unexpectedNull(column: column.name) }
        let format: PostgresFormat = column.formatCode == 1 ? .binary : .text
        let parsed = try parsePostgresArray(bytes, arrayOID: column.dataTypeOID, format: format)
        guard !parsed.dimensions.isEmpty else { return [] }        // {} → []
        var index = 0
        return try [Element]._decodeArrayLevel(parsed.dimensions[...], from: parsed.elements, at: &index,
                                               oid: parsed.elementOID, format: format, columnName: column.name)
    }
}

public extension PostgresRow {
    /// Decode a named array column into a nested Swift array. See `PostgresCell.decodeArray`.
    func decodeArray<Element: PostgresArrayDecodable>(
        _ name: String, of scalar: Element.ArrayScalar.Type = Element.ArrayScalar.self) throws -> [Element] {
        try cell(name).decodeArray(of: scalar)
    }
}
