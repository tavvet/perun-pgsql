# Connecting

Configuration, the TLS modes and what each guarantees, authentication, and the session defaults
the driver pins.

## Configuration

``ConnectionConfiguration`` holds everything needed to open a connection. Only `user` and
`database` are required; the rest have defaults.

```swift
let config = ConnectionConfiguration(
    host: "db.example.com",       // defaults to "localhost"
    port: 5432,                   // defaults to 5432
    user: "app",
    database: "app_production",
    password: "…",                // optional — omit for trust authentication
    tlsMode: .verifyFull          // the default; see below
)

let connection = try await PostgresConnection.connect(config)
```

Further options: ``ConnectionConfiguration/maxMessageSize`` (default 256 MiB) caps how large a
single backend message may be, bounding memory against a hostile or buggy server that declares a
huge length; ``ConnectionConfiguration/notificationBufferLimit`` (default 1024) bounds the
`LISTEN`/`NOTIFY` buffer; ``ConnectionConfiguration/runtimeParameters`` sets extra startup GUCs,
e.g. `["application_name": "perun"]`.

## TLS modes

``ConnectionConfiguration/tlsMode`` chooses how the connection negotiates TLS. It defaults to the
only fully-secure option, ``TLSMode/verifyFull``; the weaker modes are named for the risk they
carry, so an unsafe choice is explicit at the call site.

| Mode | Encrypted | Server authenticated | Use |
| --- | --- | --- | --- |
| ``TLSMode/verifyFull`` | yes | yes — chain **and** hostname | production; the default |
| ``TLSMode/encryptWithoutVerification`` | yes | no | encrypted but MITM-able; only on a trusted network |
| ``TLSMode/allowPlaintextFallback`` | if offered | no | opportunistic; falls back to plaintext |
| ``TLSMode/disable`` | no | no | local sockets / a trusted network only |

Only `.verifyFull` protects against a man-in-the-middle. The older `PGSSLMODE`-style names
`.prefer` and `.require` remain as deprecated aliases for `.allowPlaintextFallback` and
`.encryptWithoutVerification`.

## Authentication

The driver authenticates automatically from ``ConnectionConfiguration/password``, supporting
**SCRAM-SHA-256** (PostgreSQL's default), MD5, and cleartext-password. SCRAM is *mutually*
authenticating: the driver verifies the server proved it also knows the password, so a
man-in-the-middle without the password cannot complete the exchange — this check is enforced, not
skipped. Passwords are prepared with SASLprep (RFC 4013) before hashing, so a non-ASCII password
hashes the same way it does server-side. A missing or wrong password fails cleanly with
``SQLState/invalidPassword`` (`28P01`).

## Pinned session defaults

To give its **text** decoders a known wire format regardless of the server, role, or database
defaults, the driver pins three session GUCs at startup: `client_encoding=UTF8`, `DateStyle=ISO`,
and `IntervalStyle=postgres`. Set any of them (matched case-insensitively) in
``ConnectionConfiguration/runtimeParameters`` to override the pin — at the cost of that type's
text decoding. Binary results don't depend on `DateStyle`/`IntervalStyle`, so they're unaffected
either way.

## Closing

Call ``PostgresConnection/close()`` when you're done. A connection you simply drop is still
cleaned up — its socket is closed from `deinit` — but closing explicitly is clearer and frees the
wire immediately. Behind a ``PostgresClient`` pool, call ``PostgresClient/shutdown()`` instead; it
closes every pooled connection.
