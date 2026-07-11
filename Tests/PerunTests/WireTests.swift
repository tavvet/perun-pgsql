import XCTest
@testable import PerunPGSQL

/// Byte-exact checks on the frontend wire encoders.
final class WireTests: XCTestCase {

    func testBindTextParameter() throws {
        let message = try FrontendMessage.bind(portal: "", statement: "", parameters: [42])
        let expected: [UInt8] = [
            0x42,                       // 'B'
            0x00, 0x00, 0x00, 0x12,     // length = 18 (includes itself)
            0x00,                       // portal ""
            0x00,                       // statement ""
            0x00, 0x00,                 // 0 parameter format codes  → all text
            0x00, 0x01,                 // 1 parameter value
            0x00, 0x00, 0x00, 0x02,     // value length 2
            0x34, 0x32,                 // "42"
            0x00, 0x00,                 // 0 result format codes     → all text
        ]
        XCTAssertEqual(message, expected)
    }

    func testBindNullParameter() throws {
        let message = try FrontendMessage.bind(portal: "", statement: "", parameters: [nil])
        // Tail: 1 value, length -1 (0xFFFFFFFF = NULL), then 0 result formats.
        XCTAssertEqual(Array(message.suffix(8)),
                       [0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00])
    }

    func testFrameLengthIncludesItself() {
        // Sync is a bare tag ('S') plus a 4-byte length.
        XCTAssertEqual(FrontendMessage.sync(), [0x53, 0x00, 0x00, 0x00, 0x04])
    }

    // An embedded NUL in a startup field would smuggle extra startup parameters into the
    // unframed packet; the builder must reject it rather than encode it.
    func testStartupRejectsEmbeddedNUL() {
        XCTAssertThrowsError(try FrontendMessage.startup(user: "app\u{0}options", database: "db"))
        XCTAssertThrowsError(try FrontendMessage.startup(user: "app", database: "db\u{0}-c x=y"))
        XCTAssertThrowsError(try FrontendMessage.startup(user: "app", database: "db",
                                                         parameters: ["application_name": "a\u{0}b"]))
        XCTAssertNoThrow(try FrontendMessage.startup(user: "app", database: "db",
                                                     parameters: ["application_name": "perun"]))
    }

    func testParseWithoutParameterTypes() throws {
        let message = try FrontendMessage.parse(statement: "", query: "SELECT 1")
        let expected: [UInt8] = [
            0x50,                       // 'P'
            0x00, 0x00, 0x00, 0x10,     // length = 16 (4 + 1 + 9 + 2)
            0x00,                       // statement ""
            0x53, 0x45, 0x4C, 0x45, 0x43, 0x54, 0x20, 0x31, 0x00,  // "SELECT 1\0"
            0x00, 0x00,                 // 0 parameter type OIDs
        ]
        XCTAssertEqual(message, expected)
    }

    // Regression: a parameter count in 32768…65535 must encode via the unsigned
    // 16-bit field, not trap the process through Int16(_:). (H1)
    func testBindLargeParameterCountEncodesUnsigned() throws {
        let params = [(any PostgresEncodable)?](repeating: nil, count: 40000)
        let message = try FrontendMessage.bind(portal: "", statement: "", parameters: params)
        // Layout: tag(1) length(4) portal(1) statement(1) formatCount(2) valueCount(2)…
        // 40000 = 0x9C40, big-endian at offsets 9..10.
        XCTAssertEqual(message[9], 0x9C)
        XCTAssertEqual(message[10], 0x40)
    }

    func testBindRejectsTooManyParameters() {
        let params = [(any PostgresEncodable)?](repeating: nil, count: 70000)
        XCTAssertThrowsError(try FrontendMessage.bind(portal: "", statement: "", parameters: params)) { error in
            guard case PerunError.tooManyParameters = error else {
                return XCTFail("expected .tooManyParameters, got \(error)")
            }
        }
    }

    func testParameterizedQueryBatchMatchesIndividualMessages() throws {
        let parameters: [(any PostgresEncodable)?] = [42, "hello", nil]
        var expected = try FrontendMessage.parse(statement: "", query: "SELECT $1, $2, $3")
        expected += try FrontendMessage.bind(portal: "",
                                             statement: "",
                                             parameters: parameters,
                                             resultFormat: .binary)
        expected += FrontendMessage.describe(.portal, name: "")
        expected += FrontendMessage.execute(portal: "")
        expected += FrontendMessage.sync()

        XCTAssertEqual(try FrontendMessage.parameterizedQuery(query: "SELECT $1, $2, $3",
                                                              parameters: parameters,
                                                              resultFormat: .binary),
                       expected)
    }

    func testPreparedStatementBatchesMatchIndividualMessages() throws {
        let name = "perun_stmt_test"

        var expectedPrepare = try FrontendMessage.parse(statement: name, query: "SELECT $1")
        expectedPrepare += FrontendMessage.describe(.statement, name: name)
        expectedPrepare += FrontendMessage.sync()
        XCTAssertEqual(try FrontendMessage.prepare(statement: name, query: "SELECT $1"), expectedPrepare)

        var expectedExecute = try FrontendMessage.bind(portal: "",
                                                       statement: name,
                                                       parameters: [7],
                                                       resultFormat: .text)
        expectedExecute += FrontendMessage.execute(portal: "")
        expectedExecute += FrontendMessage.sync()
        XCTAssertEqual(try FrontendMessage.execute(statement: name,
                                                   parameters: [7],
                                                   resultFormat: .text),
                       expectedExecute)

        XCTAssertEqual(FrontendMessage.closeAndSync(.statement, name: name),
                       FrontendMessage.close(.statement, name: name) + FrontendMessage.sync())
    }

    func testFlushFraming() {
        // Flush is a bare tag ('H') plus a 4-byte length.
        XCTAssertEqual(FrontendMessage.flush(), [0x48, 0x00, 0x00, 0x00, 0x04])
    }

    func testCopyFrontendFraming() {
        // CopyData: 'd', length (4 + body), then the payload.
        XCTAssertEqual(FrontendMessage.copyData([0x41, 0x42]),
                       [0x64, 0x00, 0x00, 0x00, 0x06, 0x41, 0x42])
        // CopyDone: bare 'c' + length 4.
        XCTAssertEqual(FrontendMessage.copyDone(), [0x63, 0x00, 0x00, 0x00, 0x04])
        // CopyFail: 'f' + length + NUL-terminated message.
        XCTAssertEqual(FrontendMessage.copyFail(message: "x"),
                       [0x66, 0x00, 0x00, 0x00, 0x06, 0x78, 0x00])
    }

    func testCopyBackendDecoding() throws {
        // CopyOutResponse: Int8 format (0 = text), Int16 column count, then per-column formats.
        guard case let .copyOutResponse(format, columnFormats) =
            try BackendMessage.decode(tag: UInt8(ascii: "H"), payload: [0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00]) else {
            return XCTFail("expected copyOutResponse")
        }
        XCTAssertEqual(format, 0)
        XCTAssertEqual(columnFormats, [0, 0])

        guard case let .copyInResponse(inFormat, _) =
            try BackendMessage.decode(tag: UInt8(ascii: "G"), payload: [0x01, 0x00, 0x00]) else {
            return XCTFail("expected copyInResponse")
        }
        XCTAssertEqual(inFormat, 1)   // binary

        guard case let .copyData(bytes) =
            try BackendMessage.decode(tag: UInt8(ascii: "d"), payload: [0x41, 0x42, 0x43]) else {
            return XCTFail("expected copyData")
        }
        XCTAssertEqual(bytes, [0x41, 0x42, 0x43])

        guard case .copyDone = try BackendMessage.decode(tag: UInt8(ascii: "c"), payload: []) else {
            return XCTFail("expected copyDone")
        }
    }

    func testBackendDecoderRejectsMalformedFraming() throws {
        func assertProtocolViolation(_ tag: Unicode.Scalar, _ payload: [UInt8],
                                     _ message: String, line: UInt = #line) {
            XCTAssertThrowsError(try BackendMessage.decode(tag: UInt8(ascii: tag), payload: payload),
                                 message, line: line) { error in
                guard case PerunError.protocolViolation = error else {
                    return XCTFail("expected protocolViolation, got \(error)", line: line)
                }
            }
        }

        // DataRow ('D'): Int16 column count, then Int32 length + bytes per column. A negative count,
        // or a negative length that isn't the -1 that marks SQL NULL, is malformed — not empty/NULL.
        assertProtocolViolation("D", [0xFF, 0xFF], "negative DataRow column count")
        assertProtocolViolation("D", [0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFE], "DataRow length -2 (not -1)")
        // -1 is the one valid negative length: a single NULL column decodes cleanly.
        guard case let .dataRow(columns) =
            try BackendMessage.decode(tag: UInt8(ascii: "D"), payload: [0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF]) else {
            return XCTFail("expected dataRow")
        }
        XCTAssertEqual(columns, [nil])

        // RowDescription ('T'): a negative field count is malformed.
        assertProtocolViolation("T", [0xFF, 0xFF], "negative RowDescription field count")

        // CopyResponse ('H'/'G'): Int8 overall format, Int16 count, Int16 per column. The formats
        // are 0 (text) or 1 (binary); anything else, or a negative count, is malformed.
        assertProtocolViolation("H", [0x02, 0x00, 0x00], "overall copy format 2")
        assertProtocolViolation("H", [0x00, 0xFF, 0xFF], "negative copy column count")
        assertProtocolViolation("H", [0x00, 0x00, 0x01, 0x00, 0x02], "copy column format code 2")
    }
}
