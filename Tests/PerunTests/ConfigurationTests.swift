import XCTest
@testable import PerunPGSQL

final class ConfigurationTests: XCTestCase {

    func testConnectionConfigurationDefaultsToVerifiedTLS() {
        let configuration = ConnectionConfiguration(user: "perun", database: "perun")
        XCTAssertEqual(configuration.tlsMode, .verifyFull)
    }

    func testConnectionConfigurationDefaultsToBoundedNotificationBuffer() {
        let configuration = ConnectionConfiguration(user: "perun", database: "perun")
        XCTAssertEqual(configuration.notificationBufferLimit, 1024)
    }

    func testConnectionConfigurationAllowsCustomNotificationBufferLimit() {
        let configuration = ConnectionConfiguration(user: "perun",
                                                    database: "perun",
                                                    notificationBufferLimit: 8)
        XCTAssertEqual(configuration.notificationBufferLimit, 8)
    }

    func testConnectToRefusedPortThrowsConnectionFailed() async {
        // A refused/unreachable host must surface as PerunError.connectionFailed — the internal
        // SocketError never leaks out of connect(), so callers see one error type.
        let configuration = ConnectionConfiguration(host: "127.0.0.1", port: 1,
                                                    user: "x", database: "x", tlsMode: .disable)
        do {
            _ = try await PostgresConnection.connect(configuration)
            XCTFail("expected the connection to be refused")
        } catch let error as PerunError {
            guard case .connectionFailed = error else {
                return XCTFail("expected .connectionFailed, got \(error)")
            }
        } catch {
            XCTFail("expected a PerunError, got \(type(of: error)): \(error)")
        }
    }

    func testConnectTimeoutBoundsAConnectToABlackHole() async {
        // 192.0.2.1 is TEST-NET-1 (RFC 5737) — a reserved address that black-holes the SYN, so a
        // blocking connect would otherwise hang for the OS default (~130 s on Linux). With a short
        // connectTimeout the attempt must fail quickly; whether it ends in a timeout or a fast
        // "unreachable" doesn't matter — the guarantee under test is that it does NOT hang.
        let configuration = ConnectionConfiguration(host: "192.0.2.1", port: 5432,
                                                    user: "x", database: "x", tlsMode: .disable,
                                                    connectTimeout: .milliseconds(500))
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await PostgresConnection.connect(configuration)
            XCTFail("expected the black-hole connect to fail")
        } catch is PerunError {
            // connectionFailed — the expected outcome.
        } catch {
            XCTFail("expected a PerunError, got \(type(of: error)): \(error)")
        }
        let elapsed = clock.now - start
        XCTAssertLessThan(elapsed, .seconds(8),
                          "connect should be bounded by connectTimeout, not the OS default")
    }
}
