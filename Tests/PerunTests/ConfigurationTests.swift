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
}
