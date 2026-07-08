import Foundation
import XCTest
@testable import PerunPGSQL

/// Pipelined bulk execution: the wire-level `Sync` placement that distinguishes the
/// atomic and independent modes, plus their end-to-end semantics against a live server.
final class PipelineTests: XCTestCase {

    // MARK: - Wire layout (no server)

    func testAtomicPipelineIsBindExecutePerSetThenOneSync() throws {
        let bytes = try FrontendMessage.pipelinedExecute(
            statement: "s", parameterSets: [[Int(1)], [Int(2)]],
            parameterFormat: .text, resultFormat: .text, syncAfterEach: false)
        XCTAssertEqual(frameTags(bytes), ["B", "E", "B", "E", "S"])   // one trailing Sync
    }

    func testIndependentPipelineSyncsAfterEverySet() throws {
        let bytes = try FrontendMessage.pipelinedExecute(
            statement: "s", parameterSets: [[Int(1)], [Int(2)]],
            parameterFormat: .text, resultFormat: .text, syncAfterEach: true)
        XCTAssertEqual(frameTags(bytes), ["B", "E", "S", "B", "E", "S"])   // Sync per set
    }

    /// Split a frontend buffer into its message tags: each frame is a tag byte then an
    /// Int32 length that counts itself and the body.
    private func frameTags(_ bytes: [UInt8]) -> [Character] {
        var tags: [Character] = []
        var i = 0
        while i + 5 <= bytes.count {
            tags.append(Character(UnicodeScalar(bytes[i])))
            let length = (Int(bytes[i + 1]) << 24) | (Int(bytes[i + 2]) << 16)
                       | (Int(bytes[i + 3]) << 8) | Int(bytes[i + 4])
            i += 1 + length
        }
        return tags
    }

    // MARK: - Live semantics

    func testAtomicPipelineBulkInsert() async throws {
        let connection = try await freshTable()
        let insert = try await connection.prepare("INSERT INTO perun_pipeline_test (id) VALUES ($1)")

        let results = try await connection.pipeline(insert, [[1], [2], [3]])
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.map(\.commandTag), ["INSERT 0 1", "INSERT 0 1", "INSERT 0 1"])
        let inserted = try await ids(connection)
        XCTAssertEqual(inserted, [1, 2, 3])                    // one round trip, three rows

        try await drop(connection)
    }

    func testAtomicPipelineRollsBackOnError() async throws {
        let connection = try await freshTable()
        _ = try await connection.query("INSERT INTO perun_pipeline_test (id) VALUES (2)")   // collides with set 2
        let insert = try await connection.prepare("INSERT INTO perun_pipeline_test (id) VALUES ($1)")

        do {
            _ = try await connection.pipeline(insert, [[1], [2], [3]])
            XCTFail("the batch should fail on the duplicate id")
        } catch let error as PerunError {
            XCTAssertEqual(error.serverError?.sqlState, .uniqueViolation)
        }

        // Atomic: 1 and 3 rolled back with the failed batch — only the pre-existing 2 remains.
        let remaining = try await ids(connection)
        XCTAssertEqual(remaining, [2])
        try await drop(connection)                              // connection still usable after the failure
    }

    func testIndependentPipelineKeepsSuccessesAroundFailures() async throws {
        let connection = try await freshTable()
        _ = try await connection.query("INSERT INTO perun_pipeline_test (id) VALUES (2)")
        let insert = try await connection.prepare("INSERT INTO perun_pipeline_test (id) VALUES ($1)")

        let results = try await connection.pipelineIndependently(insert, [[1], [2], [3]])
        XCTAssertEqual(results.count, 3)
        XCTAssertNoThrow(try results[0].get())                 // 1 inserted
        XCTAssertThrowsError(try results[1].get()) {           // 2 fails, independently
            XCTAssertEqual(($0 as? PerunError)?.serverError?.sqlState, .uniqueViolation)
        }
        XCTAssertNoThrow(try results[2].get())                 // 3 inserted despite 2's failure

        let persisted = try await ids(connection)
        XCTAssertEqual(persisted, [1, 2, 3])
        try await drop(connection)
    }

    // MARK: - Helpers

    private func freshTable() async throws -> PostgresConnection {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        _ = try? await connection.query("DROP TABLE IF EXISTS perun_pipeline_test")
        _ = try await connection.query("CREATE TABLE perun_pipeline_test (id int PRIMARY KEY)")
        return connection
    }

    private func ids(_ connection: PostgresConnection) async throws -> [Int] {
        try await connection.query("SELECT id FROM perun_pipeline_test ORDER BY id")
            .rows.map { try $0.decode("id", as: Int.self) }
    }

    private func drop(_ connection: PostgresConnection) async throws {
        _ = try await connection.query("DROP TABLE perun_pipeline_test")
        try await connection.close()
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
