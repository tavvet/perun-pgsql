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
}
