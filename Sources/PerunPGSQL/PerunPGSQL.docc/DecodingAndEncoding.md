# Decoding and encoding

Turning PostgreSQL values into Swift types and back, in both the text and binary wire formats.

## Decoding a column

Read a column from a ``PostgresRow`` with `decode`, naming the Swift type:

```swift
let id = try row.decode("id", as: Int.self)
let email = try row.decode("email", as: String.self)
```

`decode` throws ``PerunError/unexpectedNull(column:)`` if the column is SQL NULL; use
`decodeIfPresent` for a nullable column, which returns `nil` instead:

```swift
let nickname = try row.decodeIfPresent("nickname", as: String.self)   // String?
```

Any type conforming to ``PostgresDecodable`` can be decoded. NULL is handled before the decoder
runs, so a decoder itself never sees it.

## Built-in types

| Swift | PostgreSQL |
| --- | --- |
| `Bool` | `bool` |
| `Int`, `Int16`, `Int32`, `Int64` | `int2`, `int4`, `int8` |
| `Float`, `Double` | `float4`, `float8` |
| `String` | `text`, `varchar`, `char`, `name`, `json`, `jsonb` |
| `Data`, `[UInt8]` | `bytea` |
| `UUID` | `uuid` |
| `Date` | `timestamp`, `timestamptz`, `date` |
| `Decimal` | `numeric` |
| ``PostgresJSON`` | `json`, `jsonb` |
| ``PostgresInterval`` | `interval` |
| ``PostgresTime`` | `time` |
| ``PostgresTimeTz`` | `timetz` |
| ``PostgresInet`` | `inet`, `cidr` |

`interval`, `time`, `timetz`, and `inet`/`cidr` have no natural Foundation counterpart, so the
driver models them directly (months/days/microseconds for an interval, address bytes plus a prefix
for an inet, and so on).

## Text and binary

PostgreSQL sends every value in one of two wire formats, and the driver decodes both. Results come
back as **text** by default; request **binary** per query with `resultFormat: .binary`. The
decoded Swift value is identical either way — the format is a wire detail, not a type choice.

## Arrays

Decode an array column with `decodeArray`, into a nested Swift array of any scalar — `[T]`,
`[[T]]`, `[T?]`, and deeper. The nesting depth must match the array's dimensionality:

```swift
let tags:   [String] = try row.decodeArray("tags", of: String.self)
let grid:   [[Int]]  = try row.decodeArray("grid", of: Int.self)
let scores: [Int?]   = try row.decodeArray("scores", of: Int.self)   // NULL elements become nil
```

To send an array as a parameter, wrap it in ``PostgresArray`` (any number of dimensions).

## Encoding parameters

Query parameters conform to ``PostgresEncodable``. Pass them positionally for `$1`, `$2`, …; they
are sent as **text** by default, or as **binary** with `parameterFormat: .binary` for types that
have a binary form:

```swift
try await connection.query(
    "INSERT INTO users (id, email, active) VALUES ($1, $2, $3)",
    [id, email, true]
)
```

## Custom types

To decode or encode your own type, conform it to ``PostgresDecodable`` and/or ``PostgresEncodable``
— the extension point a higher layer (an ORM) builds on. For a type stored as text, that is a few
lines:

```swift
enum Color: String, PostgresDecodable, PostgresEncodable {
    case red, green, blue

    static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> Color {
        let text = String(decoding: bytes, as: UTF8.self)
        guard let color = Color(rawValue: text) else {
            throw PerunError.decodingFailed(type: "Color", oid: oid, format: "\(format)", reason: text)
        }
        return color
    }

    var postgresText: String? { rawValue }
    var postgresTypeOID: Int32 { PostgresOID.text }
}
```

``PostgresOID`` provides the well-known type OIDs. `postgresTypeOID` and `postgresBinary()` have
defaults (`0` and `nil`), so a text-only encoder needs only `postgresText`.

## What isn't built in

Range and composite types have no built-in codecs — decode the raw value (as text or `[UInt8]`)
and map it yourself, or read the parts and assemble your own type. Mapping a composite type onto a
Swift `struct` is the kind of thing an ORM layer adds on top of this driver, rather than the driver
doing it for you.
