import Foundation
import XCTest
@testable import PerunPGSQL

extension XCTestCase {
    /// Shared configuration for the live-server integration tests. Skips the test unless
    /// `PERUN_PGSQL_INTEGRATION=1`, and reads the standard `PG*` environment variables
    /// (`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`, `PGSSLMODE`). `user` and
    /// `runtimeParameters` override the defaults for the tests that need to.
    func integrationConfiguration(user: String? = nil,
                                  runtimeParameters: [String: String] = [:]) throws -> ConnectionConfiguration {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PERUN_PGSQL_INTEGRATION"] == "1" else {
            throw XCTSkip("set PERUN_PGSQL_INTEGRATION=1 to run live PostgreSQL integration tests")
        }
        let tlsMode: TLSMode
        switch environment["PGSSLMODE"] {
        case "disable": tlsMode = .disable
        case "prefer", "allow-plaintext-fallback": tlsMode = .allowPlaintextFallback
        case "require", "encrypt-without-verification": tlsMode = .encryptWithoutVerification
        case "verify-full": tlsMode = .verifyFull
        default: tlsMode = .verifyFull
        }
        return ConnectionConfiguration(
            host: environment["PGHOST"] ?? "localhost",
            port: UInt16(environment["PGPORT"] ?? "") ?? 5432,
            user: user ?? (environment["PGUSER"] ?? "perun"),
            database: environment["PGDATABASE"] ?? "perun",
            password: environment["PGPASSWORD"],
            tlsMode: tlsMode,
            runtimeParameters: runtimeParameters)
    }
}
