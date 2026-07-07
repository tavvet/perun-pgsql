import XCTest
@testable import PerunPGSQL

final class ConfigurationTests: XCTestCase {

    func testConnectionConfigurationDefaultsToVerifiedTLS() {
        let configuration = ConnectionConfiguration(user: "perun", database: "perun")
        XCTAssertEqual(configuration.tlsMode, .verifyFull)
    }
}
