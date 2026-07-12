# Getting started

Install the driver, connect to PostgreSQL, and run your first query.

## Requirements

- Swift 6 or newer, on macOS 13+ or Linux.
- **OpenSSL 3**, used for TLS. PerunPGSQL locates it with `pkg-config`, so both must be installed.

### macOS (Homebrew)

```sh
brew install openssl@3 pkg-config
```

Homebrew's `openssl@3` is *keg-only*, so point `pkg-config` at it — add this to your shell profile
so every build sees it:

```sh
export PKG_CONFIG_PATH="$(brew --prefix openssl@3)/lib/pkgconfig"
```

### Linux (Debian / Ubuntu)

```sh
sudo apt install libssl-dev pkg-config
```

No extra configuration is needed — the package's `pkg-config` files land in a standard location.

## Adding the package

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/tavvet/perun-pgsql", from: "0.2.1"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [.product(name: "PerunPGSQL", package: "perun-pgsql")]
    ),
]
```

## Your first query

```swift
import PerunPGSQL

let config = ConnectionConfiguration(user: "app", database: "app", password: "secret")
let connection = try await PostgresConnection.connect(config)

let rows = try await connection.query("SELECT version() AS version").rows
print(try rows[0].decode("version", as: String.self))

try await connection.close()
```

Parameters use `$1`, `$2`, … and are sent separately from the SQL text, so the query API is
injection-safe by construction:

```swift
let email = try await connection.query(
    "SELECT email FROM users WHERE id = $1", [userID]
).rows.first?.decode("email", as: String.self)
```

## Using a pool

For anything concurrent, prefer a ``PostgresClient`` pool over a single connection — it opens
connections on demand, hands each out one request at a time, and reuses them:

```swift
let pool = PostgresClient(configuration: config, maxConnections: 8)

let count = try await pool.query("SELECT count(*)::int AS c FROM users")
    .rows[0].decode("c", as: Int.self)

await pool.shutdown()
```

## Next steps

- <doc:Connecting> — configuration, the TLS modes, and authentication in depth.
- <doc:ErrorsAndRecovery> — the error model, the reusability contract, cancellation, and timeouts.

The `Examples/` directory holds small runnable programs; run one with
`swift run Examples basic-query` (it reads `PGHOST` / `PGUSER` / … from the environment).
