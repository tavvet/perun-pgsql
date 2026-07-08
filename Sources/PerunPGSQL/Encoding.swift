/// A Swift value that can be sent as a bound query parameter.
///
/// A value can render itself as PostgreSQL **text** (always) and, optionally, as
/// **binary**. By default parameters are sent as text — the server parses them
/// according to the inferred column type. When the caller opts into binary
/// parameters, values that provide `postgresBinary()` are sent in binary and the
/// rest fall back to text.
public protocol PostgresEncodable: Sendable {
    /// The text-format rendering of the value; `nil` means SQL NULL.
    var postgresText: String? { get }

    /// A type OID hint for `Parse` (0 = let the server infer the type). Required
    /// for binary parameters so the server reads the bytes in the right layout.
    var postgresTypeOID: Int32 { get }

    /// Binary wire-format bytes for this value, or `nil` if this type has no binary
    /// encoding (the driver then sends this parameter as text). SQL NULL is
    /// signalled separately, by a `nil` element in the parameter array.
    func postgresBinary() -> [UInt8]?
}

public extension PostgresEncodable {
    var postgresTypeOID: Int32 { 0 }
    func postgresBinary() -> [UInt8]? { nil }
}

/// Big-endian bytes of a fixed-width value (the PostgreSQL binary wire order).
func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.bigEndian) { Array($0) }
}

extension String: PostgresEncodable {
    public var postgresText: String? { self }
    public var postgresTypeOID: Int32 { 25 }        // text
    public func postgresBinary() -> [UInt8]? { Array(utf8) }   // text binary == UTF-8
}

extension Int: PostgresEncodable {
    public var postgresText: String? { String(self) }
    public var postgresTypeOID: Int32 { 20 }        // int8
    public func postgresBinary() -> [UInt8]? { bigEndianBytes(Int64(self)) }
}

extension Int16: PostgresEncodable {
    public var postgresText: String? { String(self) }
    public var postgresTypeOID: Int32 { 21 }        // int2
    public func postgresBinary() -> [UInt8]? { bigEndianBytes(self) }
}

extension Int32: PostgresEncodable {
    public var postgresText: String? { String(self) }
    public var postgresTypeOID: Int32 { 23 }        // int4
    public func postgresBinary() -> [UInt8]? { bigEndianBytes(self) }
}

extension Int64: PostgresEncodable {
    public var postgresText: String? { String(self) }
    public var postgresTypeOID: Int32 { 20 }        // int8
    public func postgresBinary() -> [UInt8]? { bigEndianBytes(self) }
}

extension Double: PostgresEncodable {
    public var postgresText: String? { String(self) }
    public var postgresTypeOID: Int32 { 701 }       // float8
    public func postgresBinary() -> [UInt8]? { bigEndianBytes(bitPattern) }
}

extension Float: PostgresEncodable {
    public var postgresText: String? { String(self) }
    public var postgresTypeOID: Int32 { 700 }       // float4
    public func postgresBinary() -> [UInt8]? { bigEndianBytes(bitPattern) }
}

extension Bool: PostgresEncodable {
    public var postgresText: String? { self ? "true" : "false" }
    public var postgresTypeOID: Int32 { 16 }        // bool
    public func postgresBinary() -> [UInt8]? { [self ? 1 : 0] }
}

extension Array: PostgresEncodable where Element == UInt8 {
    public var postgresText: String? { "\\x" + hexEncode(self) }   // bytea hex input
    public var postgresTypeOID: Int32 { 17 }        // bytea
    public func postgresBinary() -> [UInt8]? { self }   // binary == raw bytes
}
