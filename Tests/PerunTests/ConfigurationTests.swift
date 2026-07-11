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

    func testConnectionConfigurationDefaultsToBoundedConnectTimeout() {
        let configuration = ConnectionConfiguration(user: "perun", database: "perun")
        XCTAssertEqual(configuration.connectTimeout, .seconds(10))
    }

    func testConnectToBlackholedHostTimesOutPromptly() async {
        // 192.0.2.1 is TEST-NET-1 (RFC 5737): not routed, so the SYN is dropped rather than
        // refused. Without a connect timeout this would hang on the OS default (~75 s); with one
        // it must fail promptly. A generous bound only fails if the timeout doesn't work at all.
        let configuration = ConnectionConfiguration(host: "192.0.2.1", port: 5432,
                                                    user: "x", database: "x", tlsMode: .disable,
                                                    connectTimeout: .milliseconds(300))
        let start = ContinuousClock().now
        do {
            _ = try await PostgresConnection.connect(configuration)
            XCTFail("expected the connection to time out")
        } catch let error as PerunError {
            guard case .connectionFailed = error else {
                return XCTFail("expected .connectionFailed, got \(error)")
            }
        } catch {
            XCTFail("expected a PerunError, got \(type(of: error)): \(error)")
        }
        XCTAssertLessThan(ContinuousClock().now - start, .seconds(10), "connect timeout did not bound the wait")
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
}
