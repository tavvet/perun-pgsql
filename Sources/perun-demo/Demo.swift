import PerunPGSQL
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct Demo {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)   // unbuffered, so progress is visible live
        let environment = ProcessInfo.processInfo.environment
        let tlsMode: TLSMode
        switch environment["PGSSLMODE"] {
        case "disable": tlsMode = .disable
        case "prefer", "allow-plaintext-fallback": tlsMode = .allowPlaintextFallback
        case "require", "encrypt-without-verification": tlsMode = .encryptWithoutVerification
        case "verify-full": tlsMode = .verifyFull
        default: tlsMode = .verifyFull
        }
        let configuration = ConnectionConfiguration(
            host: environment["PGHOST"] ?? "localhost",
            port: UInt16(environment["PGPORT"] ?? "") ?? 5432,
            user: environment["PGUSER"] ?? "perun",
            database: environment["PGDATABASE"] ?? "perun",
            password: environment["PGPASSWORD"],
            tlsMode: tlsMode
        )

        do {
            let auth = configuration.password == nil ? "no password" : "password auth"
            print("→ connecting to \(configuration.host):\(configuration.port) as \(configuration.user) (\(auth))…")
            let connection = try await PostgresConnection.connect(configuration)
            let secure = await connection.isSecure
            print("✅ connected \(secure ? "🔒 over TLS" : "(plaintext)")\n")

            let params = await connection.parameters
            if let version = params["server_version"] {
                print("server_version = \(version)\n")
            }

            // ── Simple query protocol ─────────────────────────────────────────
            try await run(connection, "SELECT 1 AS one, 'hello, perun'::text AS greeting, true AS flag")
            try await run(connection, "SELECT n, n * n AS square FROM generate_series(1, 5) AS n")

            // ── Extended protocol: parameters & prepared statements ──────────
            print("── extended protocol ──\n")
            try await connection.query("CREATE TEMP TABLE fruits (id int primary key, name text, qty int)")

            let insert = try await connection.prepare(
                "INSERT INTO fruits (id, name, qty) VALUES ($1, $2, $3)")
            try await connection.execute(insert, [1, "apple", 5])
            try await connection.execute(insert, [2, "banana", nil])       // NULL qty
            try await connection.execute(insert, [3, "cherry", 12])
            print("inserted 3 rows via one prepared statement (note the NULL qty)\n")

            print("SQL: SELECT … FROM fruits WHERE qty IS NULL OR qty > $1   [$1 = 4]")
            let picked = try await connection.query(
                "SELECT id, name, qty FROM fruits WHERE qty IS NULL OR qty > $1 ORDER BY id", [4])
            printResult(picked)

            // ── SQL-injection safety ─────────────────────────────────────────
            let evil = "Robert'); DROP TABLE fruits;--"
            print("SQL: SELECT $1::text   [$1 = \(evil)]")
            let safe = try await connection.query("SELECT $1::text AS stored", [evil])
            printResult(safe)
            let still = try await connection.query("SELECT count(*)::int AS rows FROM fruits")
            print("   fruits table still has \(still.rows[0][0].int() ?? -1) rows — injection was inert ✅\n")

            // ── typed decoding: text and binary yield identical Swift values ──
            print("── typed decoding (Foundation types, text vs binary) ──\n")
            let typedSQL = """
            SELECT 9000000000::int8 AS big, 3.5::float8 AS ratio, true AS active,
                   '550e8400-e29b-41d4-a716-446655440000'::uuid AS id,
                   '2026-07-07 20:50:24.123456+00'::timestamptz AS ts,
                   '2026-07-07'::date AS d, 1234.56::numeric AS amount,
                   '\\xdeadbeef'::bytea AS blob
            """
            for format in [PostgresFormat.text, .binary] {
                let row = try await connection.query(typedSQL, [], resultFormat: format).rows[0]
                let label = format == .binary ? "binary" : "text  "
                let id = try row["id"]!.decode(UUID.self)
                let ts = try row["ts"]!.decode(Date.self)
                let amount = try row["amount"]!.decode(Decimal.self)
                let blob = try row["blob"]!.decode(Data.self)
                print("[\(label)] big=\(try row["big"]!.decode(Int64.self))"
                    + " ratio=\(try row["ratio"]!.decode(Double.self))"
                    + " active=\(try row["active"]!.decode(Bool.self))")
                print("         id=\(id) amount=\(amount)"
                    + " blob=0x\(blob.map { String(format: "%02x", $0) }.joined())")
                print("         ts.epoch=\(ts.timeIntervalSince1970)"
                    + " d=\(try row["d"]!.decode(Date.self).timeIntervalSince1970)\n")
            }

            // ── concurrency: many parallel queries on ONE connection ─────────
            // The wire lock must serialize these, or the protocol stream corrupts.
            print("── concurrency: 10 parallel queries on a single connection ──")
            let singleSum = try await withThrowingTaskGroup(of: Int.self) { group in
                for i in 1 ... 10 {
                    group.addTask { try await connection.query("SELECT \(i) * \(i)").rows[0][0].int() ?? -1 }
                }
                var sum = 0
                for try await value in group { sum += value }
                return sum
            }
            print("   Σ squares 1..10 = \(singleSum) (expected 385) \(singleSum == 385 ? "✅" : "❌")\n")

            try await connection.close()
            print("👋 single connection closed\n")

            // ── connection pool ──────────────────────────────────────────────
            print("── connection pool (PostgresClient, max 4) ──")
            let pool = PostgresClient(configuration: configuration, maxConnections: 4)
            let poolSum = try await withThrowingTaskGroup(of: Int.self) { group in
                for i in 1 ... 20 {
                    group.addTask { try await pool.query("SELECT $1::int * $1::int", [i]).rows[0][0].int() ?? -1 }
                }
                var sum = 0
                for try await value in group { sum += value }
                return sum
            }
            let opened = await pool.connectionCount
            print("   20 parallel queries over the pool → Σ squares 1..20 = \(poolSum)"
                + " (expected 2870) \(poolSum == 2870 ? "✅" : "❌")")
            print("   pool opened \(opened) connection(s) for 20 queries (max 4)")
            await pool.shutdown()
            print("👋 pool shut down")

            // ── notices ──────────────────────────────────────────────────────
            print("\n── notices ──")
            let admin = try await PostgresConnection.connect(configuration)
            await admin.onNotice { print("   📢 NOTICE: \($0.message ?? "")") }
            try await admin.query("DROP TABLE IF EXISTS perun_absent_table")   // emits a NOTICE

            // ── LISTEN / NOTIFY ──────────────────────────────────────────────
            print("\n── LISTEN / NOTIFY ──")
            let listener = try await PostgresConnection.connect(configuration)
            try await listener.listen(to: "perun_events")
            let reader = Task { try? await listener.waitForNotifications() }
            let consumer = Task {
                var seen = 0
                for await note in listener.notifications {
                    print("   🔔 [\(note.channel)] \(note.payload)")
                    seen += 1
                    if seen == 2 { break }
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
            try await admin.query("NOTIFY perun_events, 'hello from perun'")
            try await admin.query("NOTIFY perun_events, 'second event'")
            _ = await consumer.value
            reader.cancel()
            try await listener.close()

            // ── query cancellation ───────────────────────────────────────────
            print("\n── query cancellation ──")
            let victim = try await PostgresConnection.connect(configuration)
            let longQuery = Task {
                do {
                    _ = try await victim.query("SELECT pg_sleep(10)")
                    print("   (query finished — cancel lost the race)")
                } catch {
                    print("   ⛔️ cancelled: \(error)")
                }
            }
            try await Task.sleep(nanoseconds: 400_000_000)
            try await victim.cancelCurrentQuery()
            _ = await longQuery.value
            try await victim.close()
            try await admin.close()

            print("\n🏁 all done — Perun M1–M7 exercised end to end")
        } catch {
            print("❌ \(error)")
            exit(1)
        }
    }

    static func run(_ connection: PostgresConnection, _ sql: String) async throws {
        print("SQL: \(sql)")
        let result = try await connection.query(sql)
        printResult(result)
    }

    static func printResult(_ result: QueryResult) {
        if !result.columns.isEmpty {
            print("   " + result.columns.map(\.name).joined(separator: " | "))
            for row in result.rows {
                let cells = row.columns.indices.map { row[$0].string() ?? "NULL" }
                print("   " + cells.joined(separator: " | "))
            }
        }
        print("   ⟶ \(result.commandTag) (\(result.rowCount) row(s))\n")
    }
}
