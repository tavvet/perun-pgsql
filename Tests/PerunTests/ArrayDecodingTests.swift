import Foundation
import XCTest
@testable import PerunPGSQL

/// Decoding array columns into Swift arrays: the text/binary parsers and the typed
/// `decodeArray` entry points, plus a live round-trip.
final class ArrayDecodingTests: XCTestCase {

    // MARK: - Text (no server)

    func testDecodeOneDimensionalTextArray() throws {
        let ints: [Int] = try textCell("{1,2,3}", oid: 1007).decodeArray(of: Int.self)   // _int4
        XCTAssertEqual(ints, [1, 2, 3])
        let empty: [Int] = try textCell("{}", oid: 1007).decodeArray(of: Int.self)
        XCTAssertEqual(empty, [])
    }

    func testEmptyNestedArrayEncodesAsEmpty() {
        // Rows with a zero-length dimension are an empty array: text must render as {} (not the
        // {{},{}} that PostgreSQL rejects).
        XCTAssertEqual(PostgresArray([[Int]]([[], []])).postgresText, "{}")
        // With a known element type, binary encodes the canonical empty array (ndim = 0).
        let typed = PostgresArray(dimensions: [2, 0], elements: [], elementTypeOID: PostgresOID.int8)
        XCTAssertEqual(typed.postgresText, "{}")
        XCTAssertEqual(typed.postgresBinary()?.prefix(4), [0, 0, 0, 0])   // ndim = 0
    }

    func testTextArrayQuotingAndNulls() throws {
        // A comma and an escaped quote inside quoted elements, plus an unquoted NULL.
        let texts: [String?] = try textCell(#"{plain,"a,b","c\"d",NULL}"#, oid: 1009).decodeArray(of: String.self)
        XCTAssertEqual(texts, ["plain", "a,b", "c\"d", nil])
        // The non-optional overload rejects a NULL element.
        XCTAssertThrowsError(try textCell("{1,NULL,3}", oid: 1007).decodeArray(of: Int.self) as [Int])
    }

    func testDecodeTwoDimensionalTextArray() throws {
        let matrix: [[Int]] = try textCell("{{1,2,3},{4,5,6}}", oid: 1007).decodeArray(of: Int.self)
        XCTAssertEqual(matrix, [[1, 2, 3], [4, 5, 6]])
    }

    func testDecodeThreeDimensionalTextArray() throws {
        let cube: [[[Int]]] = try textCell("{{{1,2},{3,4}},{{5,6},{7,8}}}", oid: 1007).decodeArray(of: Int.self)
        XCTAssertEqual(cube, [[[1, 2], [3, 4]], [[5, 6], [7, 8]]])
        // NULLs at depth need an optional leaf.
        let withNull: [[[Int?]]] = try textCell("{{{1,NULL}}}", oid: 1007).decodeArray(of: Int.self)
        XCTAssertEqual(withNull, [[[1, nil]]])
    }

    func testTextArrayWithNonDefaultLowerBounds() throws {
        // PostgreSQL prints an explicit `[lower:upper]=` decoration when a lower bound isn't 1.
        let ones: [Int] = try textCell("[2:4]={7,7,7}", oid: 1007).decodeArray(of: Int.self)
        XCTAssertEqual(ones, [7, 7, 7])
        let matrix: [[Int]] = try textCell("[1:2][1:3]={{1,2,3},{4,5,6}}", oid: 1007).decodeArray(of: Int.self)
        XCTAssertEqual(matrix, [[1, 2, 3], [4, 5, 6]])
    }

    func testRejectsMalformedArrays() throws {
        // Ragged: dimensions come from the first branch ([2,1]) but flattening yields three
        // elements — the reshape would silently drop the extra one without the count check.
        XCTAssertThrowsError(try textCell("{{1},{2,3}}", oid: 1007).decodeArray(of: Int.self) as [[Int]])
        // Trailing content past the closing brace.
        XCTAssertThrowsError(try textCell("{1,2,3}x", oid: 1007).decodeArray(of: Int.self) as [Int])
        // Trailing bytes past the last binary element.
        let binary: [UInt8] = [
            0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 20,   // ndim 1, flags, int8 element OID
            0, 0, 0, 1, 0, 0, 0, 1,                // dimension length 1, lower bound 1
            0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 10,   // one int8 element
            0,                                      // one byte too many
        ]
        XCTAssertThrowsError(try cell(binary, oid: 1016, binary: true).decodeArray(of: Int.self) as [Int])
    }

    func testDimensionalityMismatchThrows() throws {
        XCTAssertThrowsError(try textCell("{{1,2},{3,4}}", oid: 1007).decodeArray(of: Int.self) as [Int])     // 2-D as 1-D
        XCTAssertThrowsError(try textCell("{{{1}}}", oid: 1007).decodeArray(of: Int.self) as [[Int]])         // 3-D as 2-D
        XCTAssertThrowsError(try textCell("{{1,2},{3,4}}", oid: 1007).decodeArray(of: Int.self) as [[[Int]]]) // 2-D as 3-D
    }

    func testDeeplyNestedTextArrayRejectedInsteadOfOverflowingStack() throws {
        // A hostile value nested far beyond PostgreSQL's 6-dimension limit must be rejected, not
        // recurse until the stack overflows (an uncatchable crash a do/catch can't intercept).
        let deep = String(repeating: "{", count: 10_000)
        XCTAssertThrowsError(try textCell(deep, oid: 1007).decodeArray(of: Int.self) as [Int])
        // A legitimate 6-dimensional array (the maximum) still parses.
        let sixD: [[[[[[Int]]]]]] = try textCell("{{{{{{7}}}}}}", oid: 1007).decodeArray(of: Int.self)
        XCTAssertEqual(sixD, [[[[[[7]]]]]])
    }

    // MARK: - Binary (no server)

    func testDecodeOneDimensionalBinaryArray() throws {
        // int8[] {10, 20}: header + two 8-byte elements.
        let binary: [UInt8] = [
            0, 0, 0, 1,        // ndim 1
            0, 0, 0, 0,        // flags
            0, 0, 0, 20,       // element OID int8
            0, 0, 0, 2,        // dimension length 2
            0, 0, 0, 1,        // lower bound 1
            0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 10,   // int8 10
            0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 20,   // int8 20
        ]
        let ints: [Int] = try cell(binary, oid: 1016, binary: true).decodeArray(of: Int.self)
        XCTAssertEqual(ints, [10, 20])
    }

    func testDecodeThreeDimensionalBinaryArray() throws {
        // int8[][][] shaped [2][1][2]: header with three dimensions, then four elements.
        let binary: [UInt8] = [
            0, 0, 0, 3,        // ndim 3
            0, 0, 0, 0,        // flags
            0, 0, 0, 20,       // element OID int8
            0, 0, 0, 2, 0, 0, 0, 1,   // dimension 0: length 2, lower bound 1
            0, 0, 0, 1, 0, 0, 0, 1,   // dimension 1: length 1, lower bound 1
            0, 0, 0, 2, 0, 0, 0, 1,   // dimension 2: length 2, lower bound 1
            0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 10,
            0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 20,
            0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 30,
            0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 40,
        ]
        let cube: [[[Int]]] = try cell(binary, oid: 1016, binary: true).decodeArray(of: Int.self)
        XCTAssertEqual(cube, [[[10, 20]], [[30, 40]]])
    }

    func testBinaryArrayRejectsHugeDimensionsInsteadOfCrashing() throws {
        // ndim 3 with every dimension 0x7FFFFFFF: the element-count product overflows Int (a
        // trapping multiply) — must be rejected as malformed, not abort the process.
        let overflowing: [UInt8] = [
            0, 0, 0, 3,        // ndim 3
            0, 0, 0, 0,        // flags
            0, 0, 0, 23,       // element OID int4
            0x7F, 0xFF, 0xFF, 0xFF, 0, 0, 0, 1,   // dimension 0: length 2147483647
            0x7F, 0xFF, 0xFF, 0xFF, 0, 0, 0, 1,   // dimension 1: length 2147483647
            0x7F, 0xFF, 0xFF, 0xFF, 0, 0, 0, 1,   // dimension 2: length 2147483647
        ]
        XCTAssertThrowsError(try cell(overflowing, oid: 1007, binary: true).decodeArray(of: Int.self) as [Int])

        // ndim 2 dims [0x7FFFFFFF, 4]: no overflow, but the count dwarfs the message — must be
        // rejected before reserveCapacity attempts a multi-GB allocation.
        let oversized: [UInt8] = [
            0, 0, 0, 2,        // ndim 2
            0, 0, 0, 0,        // flags
            0, 0, 0, 23,       // element OID int4
            0x7F, 0xFF, 0xFF, 0xFF, 0, 0, 0, 1,   // dimension 0: length 2147483647
            0, 0, 0, 4, 0, 0, 0, 1,               // dimension 1: length 4
        ]
        XCTAssertThrowsError(try cell(oversized, oid: 1007, binary: true).decodeArray(of: Int.self) as [Int])
    }

    // MARK: - Live round-trip

    func testDecodeArraysLive() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())

        let ints: [Int] = try await connection.query("SELECT ARRAY[1,2,3] AS a").rows[0].decodeArray("a", of: Int.self)
        XCTAssertEqual(ints, [1, 2, 3])

        let texts: [String?] = try await connection.query("SELECT ARRAY['a','b,c',NULL]::text[] AS a")
            .rows[0].decodeArray("a", of: String.self)
        XCTAssertEqual(texts, ["a", "b,c", nil])

        let matrix: [[Int]] = try await connection.query("SELECT ARRAY[[1,2],[3,4]] AS a").rows[0].decodeArray("a", of: Int.self)
        XCTAssertEqual(matrix, [[1, 2], [3, 4]])

        // A non-1 lower bound: array_fill prints `[2:4]={7,7,7}`.
        let filled: [Int] = try await connection.query("SELECT array_fill(7, ARRAY[3], ARRAY[2]) AS a")
            .rows[0].decodeArray("a", of: Int.self)
        XCTAssertEqual(filled, [7, 7, 7])

        // Binary result columns decode the same.
        let binaryInts: [Int] = try await connection.query("SELECT ARRAY[5,6,7]::int8[] AS a", [], resultFormat: .binary)
            .rows[0].decodeArray("a", of: Int.self)
        XCTAssertEqual(binaryInts, [5, 6, 7])

        // Encode with PostgresArray, decode back.
        let uuid = UUID()
        let uuids: [UUID] = try await connection.query("SELECT $1::uuid[] AS a", [PostgresArray([uuid])])
            .rows[0].decodeArray("a", of: UUID.self)
        XCTAssertEqual(uuids, [uuid])

        // A multi-dimensional parameter round-trips through the server, as text …
        let matrixParam: [[Int]] = try await connection.query("SELECT $1::int8[] AS a", [PostgresArray([[1, 2, 3], [4, 5, 6]])])
            .rows[0].decodeArray("a", of: Int.self)
        XCTAssertEqual(matrixParam, [[1, 2, 3], [4, 5, 6]])

        // … and in binary.
        let matrixBinary: [[Int]] = try await connection.query(
            "SELECT $1::int8[] AS a", [PostgresArray([[Int64(7), 8], [9, 10]])], parameterFormat: .binary)
            .rows[0].decodeArray("a", of: Int.self)
        XCTAssertEqual(matrixBinary, [[7, 8], [9, 10]])

        // Three dimensions decode too.
        let cube: [[[Int]]] = try await connection.query("SELECT ARRAY[[[1,2],[3,4]],[[5,6],[7,8]]] AS a")
            .rows[0].decodeArray("a", of: Int.self)
        XCTAssertEqual(cube, [[[1, 2], [3, 4]], [[5, 6], [7, 8]]])

        // A three-dimensional parameter round-trips through the server.
        let cubeParam = PostgresArray(dimensions: [2, 1, 2],
                                      elements: [1, 2, 3, 4] as [PostgresEncodable?], elementTypeOID: PostgresOID.int8)
        let cubeBack: [[[Int]]] = try await connection.query("SELECT $1::int8[] AS a", [cubeParam])
            .rows[0].decodeArray("a", of: Int.self)
        XCTAssertEqual(cubeBack, [[[1, 2]], [[3, 4]]])

        try await connection.close()
    }

    // MARK: - Helpers

    private func cell(_ bytes: [UInt8], oid: Int32, binary: Bool = false) -> PostgresCell {
        PostgresCell(bytes: bytes, column: ColumnMetadata(name: "a", dataTypeOID: oid, formatCode: binary ? 1 : 0))
    }

    private func textCell(_ text: String, oid: Int32) -> PostgresCell {
        cell(Array(text.utf8), oid: oid)
    }

    private func integrationConfiguration() throws -> ConnectionConfiguration {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PERUN_PGSQL_INTEGRATION"] == "1" else {
            throw XCTSkip("set PERUN_PGSQL_INTEGRATION=1 to run live PostgreSQL integration tests")
        }
        let tlsMode: TLSMode
        switch environment["PGSSLMODE"] {
        case "disable": tlsMode = .disable
        case "require", "encrypt-without-verification": tlsMode = .encryptWithoutVerification
        default: tlsMode = .verifyFull
        }
        return ConnectionConfiguration(
            host: environment["PGHOST"] ?? "localhost",
            port: UInt16(environment["PGPORT"] ?? "") ?? 5432,
            user: environment["PGUSER"] ?? "perun",
            database: environment["PGDATABASE"] ?? "perun",
            password: environment["PGPASSWORD"],
            tlsMode: tlsMode)
    }
}
