# Bulk load and dump with COPY

Moving rows in bulk with PostgreSQL's `COPY` protocol — far faster than row-by-row `INSERT` or
`SELECT` for large data.

## COPY … FROM STDIN — load

``PostgresConnection/copyIn(_:_:)`` bulk-loads rows. Your closure receives a
``PostgresCopyInWriter`` and pushes payload chunks in the `COPY` statement's format (text, CSV, or
binary):

```swift
try await connection.copyIn("COPY people (id, name) FROM STDIN") { writer in
    for person in people {
        try await writer.write("\(person.id)\t\(person.name)\n")
    }
}
```

Returning normally finishes the copy, and the result's command tag reports the row count. Throwing
from the closure aborts the copy (a `CopyFail`, so the server rolls it back) and rethrows your
error.

## COPY … TO STDOUT — dump

``PostgresConnection/copyOut(_:)`` streams a `COPY … TO STDOUT` as a ``PostgresCopyOutSequence`` of
raw `[UInt8]` chunks, in the statement's format and opaque to the driver:

```swift
for try await chunk in try await connection.copyOut("COPY events TO STDOUT") {
    try file.write(contentsOf: chunk)
}
```

`COPY (SELECT …) TO STDOUT` works too. Each element is one `CopyData` message — for text or CSV
that is usually one row, but the protocol may split or combine them, so treat it as a byte stream,
not a row sequence.

## Wire hold

Like streaming, both directions hold the connection's wire **exclusively** for the duration and
free it on early stop or error (`copyOut` also cancels the copy server-side). The payload is the
format's own encoding — parsing or formatting rows is your job, not the driver's.
