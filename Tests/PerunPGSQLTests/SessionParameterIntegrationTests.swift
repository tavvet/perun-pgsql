import Foundation
import XCTest
@testable import PerunPGSQL

/// Live tests that the driver pins the session GUCs its text decoders rely on
/// (`client_encoding`, `DateStyle`, `IntervalStyle`), that a caller can still override any
/// of them, and that the pin overrides a non-default server-side (role) default.
final class SessionParameterIntegrationTests: XCTestCase {

    func testDriverPinsSessionParameters() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await connection.close() } }

        let encoding = try await show(connection, "client_encoding")
        XCTAssertEqual(encoding, "UTF8")
        let dateStyle = try await show(connection, "datestyle")
        XCTAssertEqual(dateStyle.hasPrefix("ISO"), true, "expected ISO DateStyle, got \(dateStyle)")
        let intervalStyle = try await show(connection, "intervalstyle")
        XCTAssertEqual(intervalStyle, "postgres")
    }

    func testCallerCanOverrideAPinnedParameter() async throws {
        let connection = try await PostgresConnection.connect(
            integrationConfiguration(runtimeParameters: ["IntervalStyle": "iso_8601"]))
        defer { Task { try? await connection.close() } }

        // The caller's value wins per key over the driver's pin.
        let intervalStyle = try await show(connection, "intervalstyle")
        XCTAssertEqual(intervalStyle, "iso_8601")
    }

    func testCallerOverrideIsCaseInsensitive() async throws {
        // GUC names are case-insensitive: a lowercase key must still replace the pinned
        // `DateStyle`/`IntervalStyle`, not send both keys with an order-dependent winner.
        let connection = try await PostgresConnection.connect(
            integrationConfiguration(runtimeParameters: ["datestyle": "SQL, DMY", "intervalstyle": "iso_8601"]))
        defer { Task { try? await connection.close() } }

        let dateStyle = try await show(connection, "datestyle")
        XCTAssertEqual(dateStyle.hasPrefix("SQL"), true, "lowercase datestyle override should win; got \(dateStyle)")
        let intervalStyle = try await show(connection, "intervalstyle")
        XCTAssertEqual(intervalStyle, "iso_8601")
    }

    func testPinOverridesRoleDefault() async throws {
        let admin = try await PostgresConnection.connect(integrationConfiguration())
        _ = try await admin.query("DROP ROLE IF EXISTS perun_pin_test")
        // Give the role the same password the connection below will present (PGPASSWORD), so this
        // works against a server that requires password auth, not only a trust setup.
        let password = ProcessInfo.processInfo.environment["PGPASSWORD"]
        let passwordClause = password.map { " PASSWORD '\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? ""
        _ = try await admin.query("CREATE ROLE perun_pin_test LOGIN\(passwordClause)")
        _ = try await admin.query("ALTER ROLE perun_pin_test SET DateStyle = 'SQL, DMY'")
        try await admin.close()

        do {
            // Connect as the role whose default DateStyle is non-ISO. The startup pin must win.
            let roleConnection = try await PostgresConnection.connect(
                integrationConfiguration(user: "perun_pin_test"))
            let dateStyle = try await show(roleConnection, "datestyle")
            XCTAssertEqual(dateStyle.hasPrefix("ISO"), true,
                           "the pin must override the role's DateStyle default; got \(dateStyle)")
            // And a text date still decodes — a non-ISO format would fail our parser.
            let decoded: Date = try await roleConnection.query("SELECT date '2026-07-09' AS d").rows[0].decode("d")
            XCTAssertEqual(decoded, Date(timeIntervalSince1970: 1_783_555_200))   // 2026-07-09 UTC
            try await roleConnection.close()
        }

        let cleanup = try await PostgresConnection.connect(integrationConfiguration())
        _ = try await cleanup.query("DROP ROLE perun_pin_test")
        try await cleanup.close()
    }

    // MARK: - Helpers

    private func show(_ connection: PostgresConnection, _ name: String) async throws -> String {
        try await connection.query("SHOW \(name)").rows[0][0].string() ?? ""
    }

}
