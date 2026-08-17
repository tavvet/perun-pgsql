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

    // MARK: - Our preparation matches PostgreSQL's SCRAM verifier

    /// A frozen SCRAM verifier captured from a live PostgreSQL 17 `CREATE ROLE … PASSWORD`
    /// (its own `pg_saslprep` + key derivation). Recomputing it from the raw password through
    /// our SASLprep reproduces it byte for byte, so interop is pinned on every run — not only
    /// when a live server is available. The salt is embedded in the string, so the
    /// recomputation is deterministic.
    func testMatchesFrozenPostgresVerifier() {
        let rawPassword = "P\u{2168}ssw\u{00AD}\u{00A0}\u{FF4F}rd"
        XCTAssertEqual(saslPrep(rawPassword), "PIXssw ord")   // Ⅸ→IX, ｏ→o, soft hyphen gone, NBSP→space
        let stored = "SCRAM-SHA-256$4096:JEKP3sFswsMo22N+27CaIw==" +
            "$suEq1bJHFXD0yZkLj9jENaGbRRrwezvVQxboQ5Alrrw=:nV5eS5N5KQi9y5NZJtnh1eGcH5dS7ncq9E3s+WbBzpA="
        assertOurVerifier(matches: stored, preparing: rawPassword)
    }

    /// The same check against a verifier PostgreSQL generates on the spot, which also exercises
    /// the whole CREATE ROLE → read path and catches any PostgreSQL-version normalization drift.
    func testMatchesPostgresStoredVerifier() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())

        let rawPassword = "P\u{2168}ssw\u{00AD}\u{00A0}\u{FF4F}rd"
        _ = try await connection.query("SET client_encoding = 'UTF8'")
        _ = try await connection.query("SET password_encryption = 'scram-sha-256'")
        _ = try await connection.query("DROP ROLE IF EXISTS perun_saslprep_test")
        _ = try await connection.query("CREATE ROLE perun_saslprep_test LOGIN PASSWORD '\(rawPassword)'")
        let stored: String = try await connection.query(
            "SELECT rolpassword FROM pg_authid WHERE rolname = 'perun_saslprep_test'")
            .rows[0].decode("rolpassword")
        _ = try await connection.query("DROP ROLE perun_saslprep_test")
        try await connection.close()

        assertOurVerifier(matches: stored, preparing: rawPassword)
    }

    // MARK: - Helpers

    /// Parse a stored `SCRAM-SHA-256$<iterations>:<salt>$<StoredKey>:<ServerKey>` verifier and
    /// assert that deriving from `rawPassword` through our SASLprep + crypto reproduces its keys.
    private func assertOurVerifier(matches stored: String, preparing rawPassword: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let sections = stored.split(separator: "$")
        let iterationsAndSalt = sections.count == 3 ? sections[1].split(separator: ":") : []
        let keys = sections.count == 3 ? sections[2].split(separator: ":") : []
        guard sections.count == 3, sections[0] == "SCRAM-SHA-256",
              iterationsAndSalt.count == 2, keys.count == 2,
              let iterations = Int(iterationsAndSalt[0]),
              let salt = Base64.decode(String(iterationsAndSalt[1])) else {
            return XCTFail("could not parse stored verifier: \(stored)", file: file, line: line)
        }
        // Recompute: if our SASLprep matches PostgreSQL's pg_saslprep, both keys match byte for byte.
        let prepared = Array(saslPrep(rawPassword).utf8)
        // No deadline here, so the derivation never throws (the only throw is a deadline overrun).
        let salted = try! PBKDF2.deriveKey(password: prepared, salt: salt, iterations: iterations, keyLength: 32)
        let clientKey = HMACSHA256.authenticate(key: salted, message: Array("Client Key".utf8))
        let ourStoredKey = Base64.encode(SHA256.hash(clientKey))
        let ourServerKey = Base64.encode(HMACSHA256.authenticate(key: salted, message: Array("Server Key".utf8)))
        XCTAssertEqual(ourStoredKey, String(keys[0]), "StoredKey mismatch", file: file, line: line)
        XCTAssertEqual(ourServerKey, String(keys[1]), "ServerKey mismatch", file: file, line: line)
    }

}
