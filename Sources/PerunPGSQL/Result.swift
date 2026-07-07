/// Metadata describing one column of a result set.
public struct ColumnMetadata: Sendable {
    public let name: String
    /// The column's PostgreSQL type OID (e.g. 23 = int4, 25 = text).
    public let dataTypeOID: Int32
    /// 0 = text format, 1 = binary format.
    public let formatCode: Int16

    init(name: String, dataTypeOID: Int32, formatCode: Int16) {
        self.name = name
        self.dataTypeOID = dataTypeOID
        self.formatCode = formatCode
    }

    init(_ field: FieldDescription) {
        self.init(name: field.name, dataTypeOID: field.dataTypeOID, formatCode: field.formatCode)
    }

    /// A copy with a different wire format code. Used when a prepared statement
    /// (described in text) is later executed requesting binary results.
    func withFormatCode(_ code: Int16) -> ColumnMetadata {
        ColumnMetadata(name: name, dataTypeOID: dataTypeOID, formatCode: code)
    }
}

/// A single cell: the raw bytes for one column in one row, plus the column's
/// metadata so it knows how to interpret itself.
///
/// In this milestone results come back in text format, so `string()` and the
/// numeric helpers parse the textual representation. Binary decoding arrives
/// with the type system in a later milestone.
public struct PostgresCell: Sendable {
    public let bytes: [UInt8]?
    public let column: ColumnMetadata

    public var isNull: Bool { bytes == nil }

    /// Decode the cell as a UTF-8 string. Correct for text-typed columns in
    /// either wire format; for typed values prefer `decode(_:)`.
    public func string() -> String? {
        bytes.map { String(decoding: $0, as: UTF8.self) }
    }

    // Convenience accessors. These delegate to the format-aware typed decoders,
    // so they work whether results arrived in text or binary. They return nil on
    // NULL or on a decoding failure; use `decode(_:)` when you want the error.
    public func int() -> Int? { bytes == nil ? nil : try? decode(Int.self) }
    public func double() -> Double? { bytes == nil ? nil : try? decode(Double.self) }
    public func bool() -> Bool? { bytes == nil ? nil : try? decode(Bool.self) }
}

/// One row of a result set.
public struct PostgresRow: Sendable {
    /// Raw column values in column order; `nil` = SQL NULL.
    public let values: [[UInt8]?]
    public let columns: [ColumnMetadata]

    /// Access a cell by column index.
    public subscript(index: Int) -> PostgresCell {
        PostgresCell(bytes: values[index], column: columns[index])
    }

    /// Access a cell by column name (first match). Returns nil if no such column.
    public subscript(name: String) -> PostgresCell? {
        guard let index = columns.firstIndex(where: { $0.name == name }) else {
            return nil
        }
        return self[index]
    }
}

/// The outcome of running one SQL statement.
public struct QueryResult: Sendable {
    public let columns: [ColumnMetadata]
    public let rows: [PostgresRow]
    /// The `CommandComplete` tag, e.g. `"SELECT 3"`, `"INSERT 0 1"`, `"UPDATE 2"`.
    public let commandTag: String

    public var rowCount: Int { rows.count }
}
