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
/// Decode it with `decode(_:)` / `decodeIfPresent(_:)`, which handle both the
/// text and binary wire formats. The `string()`/`int()`/… helpers are
/// convenience shortcuts over the same format-aware decoders.
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
    private let columnIndexByName: [String: Int]

    init(values: [[UInt8]?], columns: [ColumnMetadata]) {
        self.init(values: values,
                  columns: columns,
                  columnIndexByName: Self.makeColumnIndexByName(columns))
    }

    init(values: [[UInt8]?], columns: [ColumnMetadata], columnIndexByName: [String: Int]) {
        self.values = values
        self.columns = columns
        self.columnIndexByName = columnIndexByName
    }

    /// Access a cell by column index.
    public subscript(index: Int) -> PostgresCell {
        PostgresCell(bytes: values[index], column: columns[index])
    }

    /// Access a cell by column name (first match). Returns nil if no such column.
    public subscript(name: String) -> PostgresCell? {
        guard let index = columnIndexByName[name] else {
            return nil
        }
        return self[index]
    }

    /// Access a cell by column name, throwing if the column is not present.
    public func cell(_ name: String) throws -> PostgresCell {
        guard let cell = self[name] else {
            throw PerunError.columnNotFound(name)
        }
        return cell
    }

    /// Decode a non-NULL column by name, throwing on missing columns, NULLs, or
    /// type mismatches.
    public func decode<T: PostgresDecodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        try cell(name).decode(type)
    }

    /// Decode a nullable column by name. Missing columns still throw; SQL NULL
    /// returns nil.
    public func decodeIfPresent<T: PostgresDecodable>(_ name: String,
                                                      as type: T.Type = T.self) throws -> T? {
        try cell(name).decodeIfPresent(type)
    }

    static func makeColumnIndexByName(_ columns: [ColumnMetadata]) -> [String: Int] {
        var indexByName: [String: Int] = [:]
        indexByName.reserveCapacity(columns.count)
        for (index, column) in columns.enumerated() where indexByName[column.name] == nil {
            indexByName[column.name] = index
        }
        return indexByName
    }
}

/// The outcome of running one SQL statement.
public struct QueryResult: Sendable {
    public let columns: [ColumnMetadata]
    public let rows: [PostgresRow]
    /// The `CommandComplete` tag, e.g. `"SELECT 3"`, `"INSERT 0 1"`, `"UPDATE 2"`.
    public let commandTag: String

    init(columns: [ColumnMetadata], values: [[[UInt8]?]], commandTag: String) {
        let columnIndexByName = PostgresRow.makeColumnIndexByName(columns)
        self.init(columns: columns,
                  rows: values.map {
                      PostgresRow(values: $0, columns: columns, columnIndexByName: columnIndexByName)
                  },
                  commandTag: commandTag)
    }

    init(columns: [ColumnMetadata], rows: [PostgresRow], commandTag: String) {
        self.columns = columns
        self.rows = rows
        self.commandTag = commandTag
    }

    public var rowCount: Int { rows.count }
}
