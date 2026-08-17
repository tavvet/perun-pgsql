import XCTest
@testable import PerunPGSQL

/// Backend message length validation (H2): a server-declared length must be
/// bounded before any buffer is sized to it.
final class FramingTests: XCTestCase {
    private let cap = 256 * 1024 * 1024

    func testValidLengths() throws {
        XCTAssertEqual(try PostgresConnection.payloadLength(forMessageLength: 4, maxMessageSize: cap), 0)
        XCTAssertEqual(try PostgresConnection.payloadLength(forMessageLength: 100, maxMessageSize: cap), 96)
        // Exactly at the cap is allowed.
        XCTAssertEqual(try PostgresConnection.payloadLength(forMessageLength: 1004, maxMessageSize: 1000), 1000)
    }

    func testRejectsTooSmall() {
        // Under the 4-byte header, including the negative that 0xFFFFFFFF decodes to.
        for length in [3, 0, -1] {
            XCTAssertThrowsError(try PostgresConnection.payloadLength(forMessageLength: length, maxMessageSize: cap))
        }
    }

    func testRejectsOversized() {
        // 0x7FFFFFFF would otherwise drive a ~2GB allocation.
        XCTAssertThrowsError(
            try PostgresConnection.payloadLength(forMessageLength: 0x7FFF_FFFF, maxMessageSize: cap)
        ) { error in
            guard case PerunError.protocolViolation = error else {
                return XCTFail("expected .protocolViolation, got \(error)")
            }
        }
        // One byte over the cap is rejected.
        XCTAssertThrowsError(try PostgresConnection.payloadLength(forMessageLength: 1005, maxMessageSize: 1000))
    }
}
