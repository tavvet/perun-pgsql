import Foundation
import XCTest
@testable import PerunPGSQL

/// Typed SQLSTATE conditions and the structured `ErrorResponse` field accessors.
final class ServerErrorTests: XCTestCase {

    func testSQLStateTypingRoundTrips() {
        XCTAssertEqual(SQLState(code: "23505"), .uniqueViolation)
        XCTAssertEqual(SQLState(code: "40P01"), .deadlockDetected)
        XCTAssertEqual(SQLState.uniqueViolation.code, "23505")
        XCTAssertEqual(SQLState.deadlockDetected.code, "40P01")
        // An unnamed code is preserved verbatim, not lost.
        XCTAssertEqual(SQLState(code: "XX999"), .other("XX999"))
        XCTAssertEqual(SQLState(code: "XX999").code, "XX999")
    }

    func testSQLStateClassHelpers() {
        XCTAssertTrue(SQLState.uniqueViolation.isIntegrityConstraintViolation)
        XCTAssertTrue(SQLState.foreignKeyViolation.isIntegrityConstraintViolation)
        XCTAssertFalse(SQLState.deadlockDetected.isIntegrityConstraintViolation)
        XCTAssertTrue(SQLState.deadlockDetected.isTransactionRollback)
        XCTAssertTrue(SQLState.serializationFailure.isTransactionRollback)
        XCTAssertFalse(SQLState.uniqueViolation.isTransactionRollback)
        XCTAssertEqual(SQLState.uniqueViolation.errorClass, "23")
        XCTAssertEqual(SQLState.other("XX999").errorClass, "XX")
    }

    func testServerErrorFieldsAndTypedState() {
        // A representative unique_violation ErrorResponse.
        let error = PostgresServerError(fields: [
            UInt8(ascii: "S"): "ERROR",
            UInt8(ascii: "C"): "23505",
            UInt8(ascii: "M"): #"duplicate key value violates unique constraint "users_email_key""#,
            UInt8(ascii: "D"): "Key (email)=(a@b.com) already exists.",
            UInt8(ascii: "n"): "users_email_key",
            UInt8(ascii: "t"): "users",
            UInt8(ascii: "s"): "public",
            UInt8(ascii: "P"): "42",
        ])
        XCTAssertEqual(error.sqlState, .uniqueViolation)
        XCTAssertEqual(error.sqlStateCode, "23505")
        XCTAssertEqual(error.constraintName, "users_email_key")
        XCTAssertEqual(error.tableName, "users")
        XCTAssertEqual(error.schemaName, "public")
        XCTAssertEqual(error.position, 42)
        XCTAssertTrue(error.sqlState?.isIntegrityConstraintViolation == true)
    }

    func testUnknownCodeAndMissingFields() {
        let error = PostgresServerError(fields: [UInt8(ascii: "C"): "99999"])
        XCTAssertEqual(error.sqlState, .other("99999"))
        XCTAssertNil(error.constraintName)      // absent field → nil, not a crash
        XCTAssertNil(error.position)
    }

    func testPerunErrorServerBridge() {
        let error = PostgresServerError(fields: [UInt8(ascii: "C"): "40P01"])
        XCTAssertEqual(PerunError.server(error).serverError?.sqlState, .deadlockDetected)
        XCTAssertTrue(PerunError.server(error).serverError?.sqlState?.isTransactionRollback == true)
        XCTAssertNil(PerunError.connectionClosed.serverError)   // not a server error
    }

    /// End-to-end: a real unique violation arrives as `.uniqueViolation` with the
    /// constraint name, and the connection stays usable afterward (a server error is
    /// not a wire desync). Skipped unless PERUN_PGSQL_INTEGRATION=1.
    func testLiveUniqueViolationSurfacesTypedState() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        let table = "perun_sqlstate_probe"
        _ = try? await connection.query("DROP TABLE IF EXISTS \(table)")
        _ = try await connection.query("CREATE TABLE \(table) (email text UNIQUE)")
        _ = try await connection.query("INSERT INTO \(table) (email) VALUES ($1)", ["a@b.com"])

        do {
            _ = try await connection.query("INSERT INTO \(table) (email) VALUES ($1)", ["a@b.com"])
            XCTFail("expected a unique violation")
        } catch let error as PerunError {
            XCTAssertEqual(error.serverError?.sqlState, .uniqueViolation)
            XCTAssertEqual(error.serverError?.constraintName, "\(table)_email_key")
            XCTAssertTrue(error.serverError?.sqlState?.isIntegrityConstraintViolation == true)
        }

        // The connection is still healthy after the server error.
        _ = try await connection.query("DROP TABLE \(table)")
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
