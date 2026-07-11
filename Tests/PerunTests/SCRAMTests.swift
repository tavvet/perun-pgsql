import XCTest
@testable import PerunPGSQL

/// End-to-end SCRAM-SHA-256 client check against the official example in
/// RFC 7677 §3. If the primitives and the message assembly are all correct,
/// the client proof and the verified server signature match byte for byte.
final class SCRAMTests: XCTestCase {

    func testRFC7677Example() throws {
        var client = SCRAMClient(username: "user",
                                 password: "pencil",
                                 clientNonce: "rOprNGfwEbeRWgbNEkqO")

        let clientFirst = client.clientFirstMessage()
        XCTAssertEqual(clientFirst, "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")
        XCTAssertFalse(client.hasVerifiedServerSignature)

        let serverFirst = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,"
            + "s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"

        let clientFinal = try client.clientFinalMessage(serverFirst: serverFirst)
        XCTAssertEqual(
            clientFinal,
            "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,"
                + "p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
        XCTAssertFalse(client.hasVerifiedServerSignature)

        // Correct server signature is accepted…
        XCTAssertNoThrow(
            try client.verifyServerFinal("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="))
        XCTAssertTrue(client.hasVerifiedServerSignature)
    }

    func testServerSignatureMismatchIsRejected() throws {
        var client = SCRAMClient(username: "user",
                                 password: "pencil",
                                 clientNonce: "rOprNGfwEbeRWgbNEkqO")
        _ = client.clientFirstMessage()
        _ = try client.clientFinalMessage(
            serverFirst: "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,"
                + "s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")

        // …a tampered one is rejected (guards against a MITM / wrong password).
        XCTAssertThrowsError(
            try client.verifyServerFinal("v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM="))
        XCTAssertFalse(client.hasVerifiedServerSignature)
    }

    func testServerFinalBeforeClientFinalIsRejected() throws {
        // A server that jumps straight to SASLFinal with an empty v= (skipping SASLContinue)
        // must not be "verified" by matching the empty initial expected-signature.
        var client = SCRAMClient(password: "pencil", clientNonce: "myClientNonce")
        _ = client.clientFirstMessage()
        XCTAssertThrowsError(try client.verifyServerFinal("v="))
        XCTAssertFalse(client.hasVerifiedServerSignature)
    }

    func testWrongClientNonceRejected() {
        var client = SCRAMClient(password: "pencil", clientNonce: "myClientNonce")
        _ = client.clientFirstMessage()
        // Server nonce that does not start with our client nonce must be refused.
        XCTAssertThrowsError(
            try client.clientFinalMessage(
                serverFirst: "r=somethingElse,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"))
    }

    func testMaliciousIterationCountRejected() throws {
        func attempt(_ iterations: String) throws {
            var client = SCRAMClient(password: "pencil", clientNonce: "myClientNonce")
            _ = client.clientFirstMessage()
            _ = try client.clientFinalMessage(
                serverFirst: "r=myClientNonceEXT,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=\(iterations)")
        }
        // The iteration count is server-controlled and reaches PBKDF2 before the server is
        // authenticated. 0 and negatives would trip PBKDF2's precondition and abort the process;
        // an absurdly large value is a CPU-exhaustion DoS. All must be rejected, not trusted.
        XCTAssertThrowsError(try attempt("0"))
        XCTAssertThrowsError(try attempt("-1"))
        XCTAssertThrowsError(try attempt("2147483647"))
        XCTAssertThrowsError(try attempt("1000001"))     // just past the one-million hard cap
        // A sane count is still accepted. (That the cap itself, 1000000, is in range — rather than
        // rejected as out-of-range — is shown cheaply in testDerivationHonorsDeadline, where it
        // reaches the derivation and times out instead of throwing a range violation.)
        XCTAssertNoThrow(try attempt("4096"))
    }

    func testDerivationHonorsDeadline() {
        // A deadline already in the past must abort the (server-controlled) PBKDF2 work rather than
        // running it to completion — this is what keeps a hostile iteration count from burning CPU
        // past the connect deadline.
        var client = SCRAMClient(password: "pencil", clientNonce: "myClientNonce")
        _ = client.clientFirstMessage()
        let past = ContinuousClock().now - .seconds(1)
        XCTAssertThrowsError(
            try client.clientFinalMessage(
                serverFirst: "r=myClientNonceEXT,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=1000000", deadline: past)
        ) { error in
            // An internal deadline error, not PerunError.timedOut — connect() maps it to
            // connectionFailed, since the socket is torn down rather than left usable.
            XCTAssertTrue(error is KeyDerivationDeadlineExceeded, "expected the derivation-deadline error, got \(error)")
        }

        // A comfortable future deadline lets an ordinary derivation finish.
        var ok = SCRAMClient(password: "pencil", clientNonce: "myClientNonce")
        _ = ok.clientFirstMessage()
        XCTAssertNoThrow(
            try ok.clientFinalMessage(
                serverFirst: "r=myClientNonceEXT,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
                deadline: ContinuousClock().now + .seconds(60)))
    }
}
