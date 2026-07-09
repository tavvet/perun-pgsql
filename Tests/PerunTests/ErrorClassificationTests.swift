import XCTest
@testable import PerunPGSQL

/// `PerunError.mayHaveDesynchronizedWire` classification: which errors force a
/// pooled connection to be discarded versus reused. The two tests together cover
/// every `PerunError` case.
final class ErrorClassificationTests: XCTestCase {

    func testWireDesynchronizingErrorsAreNotReusable() {
        let errors: [PerunError] = [
            .connectionClosed,
            .ioError("recv() failed — errno 54"),
            .connectionFailed("could not connect to db:5432"),
            .protocolViolation("bad frame"),
            .tlsHandshakeFailed("bad cert"),
            .tlsIO("read failed"),
            .tlsNotAvailable,
            .authenticationFailed("bad proof"),
            .unsupportedAuthentication("gss"),
        ]

        for error in errors {
            XCTAssertTrue(error.mayHaveDesynchronizedWire, "\(error) should drop pooled connection")
        }
    }

    func testLocalAndDrainedServerErrorsAreReusable() {
        let server = PostgresServerError(fields: [
            UInt8(ascii: "S"): "ERROR",
            UInt8(ascii: "C"): "42601",
            UInt8(ascii: "M"): "syntax error",
        ])
        let errors: [PerunError] = [
            .server(server),
            .unexpectedNull(column: "name"),
            .columnNotFound("name"),
            .decodingFailed(type: "Int", oid: PostgresOID.int4, format: "text", reason: "1 bytes"),
            .tooManyParameters(count: 65536),
            .clientShutdown,
            .preparedStatementConnectionMismatch,
            .copyMismatch("wrong direction"),
        ]

        for error in errors {
            XCTAssertFalse(error.mayHaveDesynchronizedWire, "\(error) should reuse pooled connection")
        }
    }
}
