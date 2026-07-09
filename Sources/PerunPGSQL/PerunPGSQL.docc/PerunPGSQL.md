# ``PerunPGSQL``

A from-scratch PostgreSQL driver for Swift, built directly on the v3 wire protocol.

## Overview

PerunPGSQL talks to PostgreSQL over its native wire protocol — no libpq, and apart from OpenSSL
for TLS, no third-party dependencies. It gives you connections and a pool, parameterised queries,
transactions, row streaming, `COPY`, `LISTEN`/`NOTIFY`, and typed decoding in both the text and
binary formats, all on Swift's `async`/`await` concurrency.

It is a **data-access driver, not a query builder**. It moves rows and values to and from the
server; building SQL, mapping tables to model types, and migrations belong to a higher layer.

```swift
let pool = PostgresClient(configuration: config, maxConnections: 8)

let rows = try await pool.query("SELECT id, email FROM users WHERE id = $1", [id]).rows
let email = try rows[0].decode("email", as: String.self)

try await pool.shutdown()
```

Parameters are always sent out of band (`$1`, `$2`, …), never spliced into the SQL text, so the
query API is injection-safe by construction.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Connecting>
- ``PostgresConnection``
- ``PostgresClient``
- ``ConnectionConfiguration``

### Working with data

- <doc:Queries>
- <doc:Transactions>
- <doc:ConnectionPool>
- ``PreparedStatement``

### Handling failure

- <doc:ErrorsAndRecovery>
- ``PerunError``
- ``PostgresServerError``
- ``SQLState``
- ``withTimeout(_:_:)``

### Working with results

- ``QueryResult``
- ``PostgresRow``
- ``PostgresCell``

### Decoding and encoding

- ``PostgresDecodable``
- ``PostgresEncodable``
