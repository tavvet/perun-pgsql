import XCTest
@testable import PerunPGSQL

/// SASLprep (RFC 4013) password preparation: the mapping, NFKC normalization, and
/// prohibited-output fallback, plus a live check that our result matches the SCRAM
/// verifier PostgreSQL stores after running its own `pg_saslprep`.
final class SASLprepTests: XCTestCase {

    func testASCIIIsUnchanged() {
        XCTAssertEqual(saslPrep("password"), "password")
        XCTAssertEqual(saslPrep("p@ssw0rd! 123"), "p@ssw0rd! 123")
        XCTAssertEqual(saslPrep(""), "")
    }

    func testRFC4013MappingAndNormalization() {
        // Soft hyphen is "mapped to nothing".
        XCTAssertEqual(saslPrep("I\u{00AD}X"), "IX")
        // FEMININE ORDINAL INDICATOR ª normalizes to "a".
        XCTAssertEqual(saslPrep("\u{00AA}"), "a")
        // ROMAN NUMERAL NINE Ⅸ normalizes to "IX".
        XCTAssertEqual(saslPrep("\u{2168}"), "IX")
    }

    func testNonASCIISpacesMapToSpace() {
        XCTAssertEqual(saslPrep("\u{00A0}"), " ")       // NO-BREAK SPACE
        XCTAssertEqual(saslPrep("\u{3000}"), " ")       // IDEOGRAPHIC SPACE
        XCTAssertEqual(saslPrep("a\u{2003}b"), "a b")   // EM SPACE
    }

    func testMappedToNothingAreRemoved() {
        XCTAssertEqual(saslPrep("a\u{200B}b"), "ab")    // ZERO WIDTH SPACE
        XCTAssertEqual(saslPrep("x\u{FEFF}y"), "xy")    // ZERO WIDTH NO-BREAK SPACE
    }

    func testCompatibilityNormalization() {
        XCTAssertEqual(saslPrep("\u{FF11}\u{FF12}\u{FF13}"), "123")   // fullwidth digits
        XCTAssertEqual(saslPrep("e\u{0301}"), "\u{00E9}")            // e + combining acute → é
    }

    func testProhibitedFallsBackToOriginal() {
        // A non-ASCII control character is prohibited; PostgreSQL (and we) fall back to the
        // original password rather than failing, so both sides still agree.
        let withControl = "a\u{0085}b"   // NEL, a non-ASCII control
        XCTAssertEqual(saslPrep(withControl), withControl)
    }

    // MARK: - Live: our preparation matches PostgreSQL's stored SCRAM verifier

    func testMatchesPostgresStoredVerifier() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())

        // A password whose SASLprep is not the identity: Ⅸ → "IX", soft hyphen removed.
        let rawPassword = "p\u{2168}ssw\u{00AD}rd"
        _ = try await connection.query("SET client_encoding = 'UTF8'")
        _ = try await connection.query("SET password_encryption = 'scram-sha-256'")
        _ = try await connection.query("DROP ROLE IF EXISTS perun_saslprep_test")
        _ = try await connection.query("CREATE ROLE perun_saslprep_test LOGIN PASSWORD '\(rawPassword)'")
        let stored: String = try await connection.query(
            "SELECT rolpassword FROM pg_authid WHERE rolname = 'perun_saslprep_test'")
            .rows[0].decode("rolpassword")
        _ = try await connection.query("DROP ROLE perun_saslprep_test")
        try await connection.close()

        // rolpassword: SCRAM-SHA-256$<iterations>:<salt>$<StoredKey>:<ServerKey> (salt/keys base64).
        let sections = stored.split(separator: "$")
        XCTAssertEqual(sections.count, 3, "unexpected verifier format: \(stored)")
        let iterationsAndSalt = sections[1].split(separator: ":")
        let keys = sections[2].split(separator: ":")
        guard sections[0] == "SCRAM-SHA-256",
              iterationsAndSalt.count == 2, keys.count == 2,
              let iterations = Int(iterationsAndSalt[0]),
              let salt = Base64.decode(String(iterationsAndSalt[1])) else {
            return XCTFail("could not parse stored verifier: \(stored)")
        }
        let pgStoredKey = String(keys[0])
        let pgServerKey = String(keys[1])

        // Recompute the verifier from the raw password through our SASLprep + crypto. If our
        // preparation matches PostgreSQL's pg_saslprep, both keys match byte for byte.
        let prepared = Array(saslPrep(rawPassword).utf8)
        let salted = PBKDF2.deriveKey(password: prepared, salt: salt, iterations: iterations, keyLength: 32)
        let clientKey = HMACSHA256.authenticate(key: salted, message: Array("Client Key".utf8))
        let ourStoredKey = Base64.encode(SHA256.hash(clientKey))
        let ourServerKey = Base64.encode(HMACSHA256.authenticate(key: salted, message: Array("Server Key".utf8)))

        XCTAssertEqual(ourStoredKey, pgStoredKey)
        XCTAssertEqual(ourServerKey, pgServerKey)
    }

    // MARK: - Helpers

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
