import XCTest
@testable import PerunPGSQL

final class ResultTests: XCTestCase {

    func testRowCellByNameThrowsWhenColumnIsMissing() {
        let row = makeRow(values: [Array("1".utf8)],
                          columns: [ColumnMetadata(name: "id",
                                                   dataTypeOID: PostgresOID.int4,
                                                   formatCode: 0)])

        XCTAssertNil(row["missing"])
        XCTAssertThrowsError(try row.cell("missing")) { error in
            guard case PerunError.columnNotFound("missing") = error else {
                return XCTFail("expected .columnNotFound, got \(error)")
            }
        }
    }

    func testRowDecodeByName() throws {
        let row = makeRow(values: [Array("42".utf8)],
                          columns: [ColumnMetadata(name: "answer",
                                                   dataTypeOID: PostgresOID.int4,
                                                   formatCode: 0)])

        XCTAssertEqual(try row.decode("answer", as: Int.self), 42)
    }

    func testRowDecodeIfPresentByNameKeepsMissingAndNullDistinct() throws {
        let row = makeRow(values: [nil],
                          columns: [ColumnMetadata(name: "maybe",
                                                   dataTypeOID: PostgresOID.text,
                                                   formatCode: 0)])

        let value: String? = try row.decodeIfPresent("maybe", as: String.self)
        XCTAssertNil(value)
        XCTAssertThrowsError(try row.decodeIfPresent("missing", as: String.self)) { error in
            guard case PerunError.columnNotFound("missing") = error else {
                return XCTFail("expected .columnNotFound, got \(error)")
            }
        }
    }

    private func makeRow(values: [[UInt8]?], columns: [ColumnMetadata]) -> PostgresRow {
        PostgresRow(values: values, columns: columns)
    }
}
