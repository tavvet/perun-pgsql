import Foundation
import PerunPGSQL

/// Connection settings for the examples, read from the standard `PG*` environment variables — the
/// same convention as `psql` and the test suite. Set `PGHOST` / `PGPORT` / `PGUSER` / `PGDATABASE`
/// / `PGPASSWORD` / `PGSSLMODE` to point at your server; the defaults target a local instance.
func exampleConfiguration() -> ConnectionConfiguration {
    let environment = ProcessInfo.processInfo.environment
    let tlsMode: TLSMode
    switch environment["PGSSLMODE"] {
    case "disable": tlsMode = .disable
    case "require", "encrypt-without-verification": tlsMode = .encryptWithoutVerification
    default: tlsMode = .verifyFull
    }
    return ConnectionConfiguration(
        host: environment["PGHOST"] ?? "localhost",
        port: UInt16(environment["PGPORT"] ?? "") ?? 5432,
        user: environment["PGUSER"] ?? "perun",
        database: environment["PGDATABASE"] ?? "perun",
        password: environment["PGPASSWORD"],
        tlsMode: tlsMode)
}
