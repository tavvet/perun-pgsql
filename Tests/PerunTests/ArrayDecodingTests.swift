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

    func testDimensionalityMismatchThrows() throws {
        XCTAssertThrowsError(try textCell("{{1,2},{3,4}}", oid: 1007).decodeArray(of: Int.self) as [Int])     // 2-D as 1-D
        XCTAssertThrowsError(try textCell("{{{1}}}", oid: 1007).decodeArray(of: Int.self) as [[Int]])         // 3-D as 2-D
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

        // Binary result columns decode the same.
        let binaryInts: [Int] = try await connection.query("SELECT ARRAY[5,6,7]::int8[] AS a", [], resultFormat: .binary)
            .rows[0].decodeArray("a", of: Int.self)
        XCTAssertEqual(binaryInts, [5, 6, 7])

        // Encode with PostgresArray, decode back.
        let uuid = UUID()
        let uuids: [UUID] = try await connection.query("SELECT $1::uuid[] AS a", [PostgresArray([uuid])])
            .rows[0].decodeArray("a", of: UUID.self)
        XCTAssertEqual(uuids, [uuid])

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
