/// Whether a value is on the wire in text or binary format.
public enum PostgresFormat: Sendable, Equatable {
    case text
    case binary
}

/// A Swift type that can be decoded from a PostgreSQL value's raw bytes.
///
/// Implementations receive the bytes, the column's type OID, and the wire
/// format, and must handle both `.text` and `.binary` where the driver may
/// request either. NULL is handled one level up (in `PostgresCell`), so a
/// decoder never sees a NULL.
public protocol PostgresDecodable: Sendable {
    static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> Self
}

/// Well-known built-in type OIDs (from `pg_type`).
public enum PostgresOID {
    public static let bool: Int32 = 16
    public static let bytea: Int32 = 17
    public static let name: Int32 = 19
    public static let int8: Int32 = 20
    public static let int2: Int32 = 21
    public static let int4: Int32 = 23
    public static let text: Int32 = 25
    public static let json: Int32 = 114
    public static let float4: Int32 = 700
    public static let float8: Int32 = 701
    public static let bpchar: Int32 = 1042
    public static let varchar: Int32 = 1043
    public static let date: Int32 = 1082
    public static let time: Int32 = 1083
    public static let timestamp: Int32 = 1114
    public static let timestamptz: Int32 = 1184
    public static let interval: Int32 = 1186
    public static let numeric: Int32 = 1700
    public static let uuid: Int32 = 2950
    public static let jsonb: Int32 = 3802
}

// MARK: - Typed access on a cell

public extension PostgresCell {
    /// Decode this cell into `T`. Throws `PerunError.unexpectedNull` if the cell
    /// is SQL NULL — use `decodeIfPresent` for nullable columns.
    func decode<T: PostgresDecodable>(_ type: T.Type = T.self) throws -> T {
        guard let bytes else {
            throw PerunError.unexpectedNull(column: column.name)
        }
        let format: PostgresFormat = column.formatCode == 1 ? .binary : .text
        return try T.decode(bytes, oid: column.dataTypeOID, format: format)
    }

    /// Decode this cell into `T`, or `nil` if it is SQL NULL.
    func decodeIfPresent<T: PostgresDecodable>(_ type: T.Type = T.self) throws -> T? {
        bytes == nil ? nil : try decode(type)
    }
}

// MARK: - Shared helpers for decoders

/// Big-endian integer readers over exact-length byte slices.
enum WireBinary {
    static func uint16(_ b: [UInt8]) -> UInt16 {
        (UInt16(b[0]) << 8) | UInt16(b[1])
    }
    static func uint32(_ b: [UInt8]) -> UInt32 {
        (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }
    static func uint64(_ b: [UInt8]) -> UInt64 {
        var value: UInt64 = 0
        for byte in b { value = (value << 8) | UInt64(byte) }
        return value
    }
}

func postgresDecodeError(_ type: String, oid: Int32, format: PostgresFormat, _ bytes: [UInt8]) -> PerunError {
    return .decodingFailed(type: type,
                           oid: oid,
                           format: format == .binary ? "binary" : "text",
                           reason: postgresDecodeErrorReason(bytes))
}

private func postgresDecodeErrorReason(_ bytes: [UInt8]) -> String {
#if PERUN_ENABLE_DECODE_ERROR_BYTE_PREVIEW
    let preview = bytes.count <= 16
        ? hexEncode(bytes)
        : hexEncode(Array(bytes.prefix(16))) + "…"
    return "\(bytes.count) bytes [\(preview)]"
#else
    return "\(bytes.count) bytes"
#endif
}

func utf8String(_ bytes: [UInt8]) -> String {
    String(decoding: bytes, as: UTF8.self)
}
