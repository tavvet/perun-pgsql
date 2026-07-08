/// A Swift value that can be sent as a bound query parameter.
///
/// Parameters travel in PostgreSQL **text** format: each value is rendered to its
/// textual SQL form and the server parses it according to the inferred column
/// type. (Binary parameter encoding is a possible future optimization.)
public protocol PostgresEncodable: Sendable {
    /// The text-format rendering of the value; `nil` means SQL NULL.
    var postgresText: String? { get }

    /// A type OID hint for `Parse` (0 = let the server infer the type).
    var postgresTypeOID: Int32 { get }
}

public extension PostgresEncodable {
    var postgresTypeOID: Int32 { 0 }
}

extension String: PostgresEncodable {
    public var postgresText: String? { self }
    public var postgresTypeOID: Int32 { 25 }        // text
}

extension Int: PostgresEncodable {
    public var postgresText: String? { String(self) }
    public var postgresTypeOID: Int32 { 20 }        // int8
}

extension Int16: PostgresEncodable {
    public var postgresText: String? { String(self) }
    public var postgresTypeOID: Int32 { 21 }        // int2
}

extension Int32: PostgresEncodable {
    public var postgresText: String? { String(self) }
    public var postgresTypeOID: Int32 { 23 }        // int4
}

extension Int64: PostgresEncodable {
    public var postgresText: String? { String(self) }
    public var postgresTypeOID: Int32 { 20 }        // int8
}

extension Double: PostgresEncodable {
    public var postgresText: String? { String(self) }
    public var postgresTypeOID: Int32 { 701 }       // float8
}

extension Float: PostgresEncodable {
    public var postgresText: String? { String(self) }
    public var postgresTypeOID: Int32 { 700 }       // float4
}

extension Bool: PostgresEncodable {
    public var postgresText: String? { self ? "true" : "false" }
    public var postgresTypeOID: Int32 { 16 }        // bool
}
