import Foundation
import XCTest
@testable import PerunPGSQL

/// Transparent pipelining: concurrent autocommit queries on one connection are in
/// flight together and each caller still gets its own response (order is the
/// correlation), while an exclusive holder (a transaction) pins the connection and
/// keeps queries out until it commits. Skipped unless PERUN_PGSQL_INTEGRATION=1.
final class PipeliningIntegrationTests: XCTestCase {

    func testConcurrentQueriesEachGetTheirOwnResult() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())

        // Fire 50 distinct queries concurrently on ONE connection; if the reader
        // mismatched responses to callers, some result would be wrong.
        let results = try await withThrowingTaskGroup(of: (Int, Int).self) { group -> [Int: Int] in
            for i in 1 ... 50 {
                group.addTask {
                    (i, try await connection.query("SELECT \(i) AS n").rows[0].decode("n", as: Int.self))
                }
            }
            var byRequest: [Int: Int] = [:]
            for try await (i, n) in group { byRequest[i] = n }
            return byRequest
        }

        for i in 1 ... 50 { XCTAssertEqual(results[i], i, "query \(i) got another query's result") }
        try await connection.close()
    }

    func testConcurrentQueryWaitsForTransactionToCommit() async throws {
        let connection = try await PostgresConnection.connect(integrationConfiguration())
        _ = try? await connection.query("DROP TABLE IF EXISTS perun_pin_test")
        _ = try await connection.query("CREATE TABLE perun_pin_test (id int)")

        // A transaction inserts two rows and then holds the connection exclusively.
        let gate = Gate()
        let transaction = Task {
            try await connection.withTransaction { tx in
                _ = try await tx.query("INSERT INTO perun_pin_test (id) VALUES (1)")
                _ = try await tx.query("INSERT INTO perun_pin_test (id) VALUES (2)")
                await gate.wait()
            }
        }
        try await Task.sleep(nanoseconds: 80_000_000)          // let the transaction take exclusive access

        // This query is pinned out until the transaction commits — then it sees both rows.
        // (Were it not pinned, it would run in another session mid-transaction and see 0,
        //  or corrupt the wire by reading concurrently with the transaction.)
        let counting = Task {
            try await connection.query("SELECT count(*) AS c FROM perun_pin_test").rows[0].decode("c", as: Int.self)
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        await gate.open()                                       // commit the transaction

        let count = try await counting.value
        XCTAssertEqual(count, 2)
        try await transaction.value

        _ = try await connection.query("DROP TABLE perun_pin_test")
        try await connection.close()
    }

    private func integrationConfiguration() throws -> ConnectionConfiguration {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PERUN_PGSQL_INTEGRATION"] == "1" else {
            throw XCTSkip("set PERUN_PGSQL_INTEGRATION=1 to run live PostgreSQL integration tests")
        }
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
}

/// A one-shot gate (see the cancellation tests) — holds a connection until released.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
