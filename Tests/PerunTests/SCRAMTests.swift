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

        let serverFirst = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,"
            + "s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"

        let clientFinal = try client.clientFinalMessage(serverFirst: serverFirst)
        XCTAssertEqual(
            clientFinal,
            "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,"
                + "p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")

        // Correct server signature is accepted…
        XCTAssertNoThrow(
            try client.verifyServerFinal("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="))
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
    }

    func testWrongClientNonceRejected() {
        var client = SCRAMClient(password: "pencil", clientNonce: "myClientNonce")
        _ = client.clientFirstMessage()
        // Server nonce that does not start with our client nonce must be refused.
        XCTAssertThrowsError(
            try client.clientFinalMessage(
                serverFirst: "r=somethingElse,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"))
    }
}
