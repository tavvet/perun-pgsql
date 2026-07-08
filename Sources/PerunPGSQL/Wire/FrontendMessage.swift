/// Whether a Describe/Close targets a prepared statement or a portal.
enum StatementOrPortal {
    case statement
    case portal

    var tag: UInt8 {
        self == .statement ? UInt8(ascii: "S") : UInt8(ascii: "P")
    }
}

/// Builders for the messages we send to the server (the "frontend" side of the
/// PostgreSQL frontend/backend protocol, version 3.0).
///
/// Every message except the initial startup packet is framed as:
///     Byte1  message-type tag
///     Int32  length (includes these 4 bytes, excludes the tag)
///     …      payload
enum FrontendMessage {

    /// Protocol version 3.0 encoded as (major << 16) | minor.
    static let protocolVersion: Int32 = 196_608

    /// The very first thing sent on a new connection. It has no type tag — just
    /// a length, the protocol version, and NUL-terminated key/value parameters
    /// ending with an empty key.
    static func startup(user: String,
                        database: String,
                        parameters: [String: String] = [:]) -> [UInt8] {
        var body = ByteWriter()
        body.writeInt32(protocolVersion)
        body.writeCString("user")
        body.writeCString(user)
        body.writeCString("database")
        body.writeCString(database)
        for (key, value) in parameters {
            body.writeCString(key)
            body.writeCString(value)
        }
        body.writeUInt8(0)      // terminating empty key

        var message = ByteWriter()
        message.writeInt32(Int32(body.bytes.count + 4))
        message.writeBytes(body.bytes)
        return message.bytes
    }

    /// `SSLRequest`: sent before the startup message to ask the server to switch
    /// the connection to TLS. Like startup, it has no type tag — just a length
    /// and the magic request code. The server replies with a single byte,
    /// 'S' (proceed with TLS) or 'N' (not supported).
    static func sslRequest() -> [UInt8] {
        var message = ByteWriter()
        message.writeInt32(8)                       // length (self + code)
        message.writeInt32(80_877_103)              // (1234 << 16) | 5679
        return message.bytes
    }

    /// `CancelRequest`: sent on a *separate* connection to ask the server to
    /// cancel the query running on the backend identified by `processID` /
    /// `secretKey`. Like startup, it carries no type tag.
    static func cancelRequest(processID: Int32, secretKey: Int32) -> [UInt8] {
        var message = ByteWriter()
        message.writeInt32(16)                      // length
        message.writeInt32(80_877_102)              // (1234 << 16) | 5678
        message.writeInt32(processID)
        message.writeInt32(secretKey)
        return message.bytes
    }

    /// Simple Query protocol: a single string that may contain several
    /// statements separated by `;`.
    static func query(_ sql: String) -> [UInt8] {
        var body = ByteWriter()
        body.writeCString(sql)
        return frame(tag: "Q", body: body.bytes)
    }

    /// A password response (`PasswordMessage`). Used for cleartext auth and, in
    /// later milestones, to carry MD5 and SASL payloads.
    static func password(_ payload: String) -> [UInt8] {
        var body = ByteWriter()
        body.writeCString(payload)
        return frame(tag: "p", body: body.bytes)
    }

    /// Begin a SASL exchange (`SASLInitialResponse`): the chosen mechanism name
    /// plus our first message. Shares the `p` tag with PasswordMessage.
    static func saslInitialResponse(mechanism: String, initialResponse: [UInt8]) -> [UInt8] {
        var body = ByteWriter()
        body.writeCString(mechanism)
        body.writeInt32(Int32(initialResponse.count))
        body.writeBytes(initialResponse)
        return frame(tag: "p", body: body.bytes)
    }

    /// A continuation of a SASL exchange (`SASLResponse`): just the mechanism
    /// data, no length prefix inside the payload.
    static func saslResponse(_ data: [UInt8]) -> [UInt8] {
        frame(tag: "p", body: data)
    }

    // MARK: - Extended query protocol

    /// `Parse`: create a (possibly named) prepared statement from SQL with `$n`
    /// placeholders. An empty `parameterTypeOIDs` lets the server infer types.
    static func parse(statement: String, query: String, parameterTypeOIDs: [Int32] = []) throws -> [UInt8] {
        // The count field is an unsigned 16-bit integer on the wire.
        guard parameterTypeOIDs.count <= 65535 else {
            throw PerunError.tooManyParameters(count: parameterTypeOIDs.count)
        }
        var body = ByteWriter()
        appendParseBody(to: &body, statement: statement, query: query, parameterTypeOIDs: parameterTypeOIDs)
        return frame(tag: "P", body: body.bytes)
    }

    /// `Bind`: bind parameter values to a statement, creating a portal.
    ///
    /// We send all parameters and request all results in **text** format (both
    /// format-code counts are zero, which means "all default = text"). Binary
    /// formats arrive with the type system in a later milestone.
    static func bind(portal: String,
                     statement: String,
                     parameters: [(any PostgresEncodable)?],
                     resultFormat: PostgresFormat = .text) throws -> [UInt8] {
        // The parameter-count field is an unsigned 16-bit integer; PostgreSQL
        // allows up to 65535 bind parameters. Encoding a larger count with the
        // trapping Int16(_:) initializer would abort the whole process.
        guard parameters.count <= 65535 else {
            throw PerunError.tooManyParameters(count: parameters.count)
        }
        var body = ByteWriter()
        appendBindBody(to: &body,
                       portal: portal,
                       statement: statement,
                       parameters: parameters,
                       resultFormat: resultFormat)
        return frame(tag: "B", body: body.bytes)
    }

    /// `Describe` a prepared statement or a portal, to learn its shape.
    static func describe(_ target: StatementOrPortal, name: String) -> [UInt8] {
        var body = ByteWriter()
        body.writeUInt8(target.tag)
        body.writeCString(name)
        return frame(tag: "D", body: body.bytes)
    }

    /// `Execute` a portal, returning at most `maxRows` rows (0 = all).
    static func execute(portal: String, maxRows: Int32 = 0) -> [UInt8] {
        var body = ByteWriter()
        body.writeCString(portal)
        body.writeInt32(maxRows)
        return frame(tag: "E", body: body.bytes)
    }

    /// `Close` a prepared statement or portal, freeing its server-side resources.
    static func close(_ target: StatementOrPortal, name: String) -> [UInt8] {
        var body = ByteWriter()
        body.writeUInt8(target.tag)
        body.writeCString(name)
        return frame(tag: "C", body: body.bytes)
    }

    /// `Sync`: close the current transaction step and ask for ReadyForQuery.
    static func sync() -> [UInt8] {
        frame(tag: "S", body: [])
    }

    static func parameterizedQuery(query: String,
                                   parameters: [(any PostgresEncodable)?],
                                   resultFormat: PostgresFormat) throws -> [UInt8] {
        var request = ByteWriter(reservingCapacity: estimatedExtendedQueryCapacity(query: query,
                                                                                  statement: "",
                                                                                  parameters: parameters))
        try appendParse(to: &request, statement: "", query: query)
        try appendBind(to: &request, portal: "", statement: "", parameters: parameters, resultFormat: resultFormat)
        appendDescribe(to: &request, .portal, name: "")
        appendExecute(to: &request, portal: "")
        appendSync(to: &request)
        return request.bytes
    }

    static func prepare(statement: String, query: String) throws -> [UInt8] {
        var request = ByteWriter(reservingCapacity: estimatedExtendedQueryCapacity(query: query,
                                                                                  statement: statement,
                                                                                  parameters: []))
        try appendParse(to: &request, statement: statement, query: query)
        appendDescribe(to: &request, .statement, name: statement)
        appendSync(to: &request)
        return request.bytes
    }

    static func execute(statement: String,
                        parameters: [(any PostgresEncodable)?],
                        resultFormat: PostgresFormat) throws -> [UInt8] {
        var request = ByteWriter(reservingCapacity: estimatedExtendedQueryCapacity(query: "",
                                                                                  statement: statement,
                                                                                  parameters: parameters))
        try appendBind(to: &request, portal: "", statement: statement, parameters: parameters, resultFormat: resultFormat)
        appendExecute(to: &request, portal: "")
        appendSync(to: &request)
        return request.bytes
    }

    static func closeAndSync(_ target: StatementOrPortal, name: String) -> [UInt8] {
        var request = ByteWriter(reservingCapacity: name.utf8.count + 16)
        appendClose(to: &request, target, name: name)
        appendSync(to: &request)
        return request.bytes
    }

    /// Politely tell the server we're done.
    static func terminate() -> [UInt8] {
        frame(tag: "X", body: [])
    }

    /// Prefix a payload with its one-byte tag and Int32 length.
    static func frame(tag: Character, body: [UInt8]) -> [UInt8] {
        var message = ByteWriter(reservingCapacity: body.count + 5)
        message.writeUInt8(tag.asciiValue!)
        message.writeInt32(Int32(body.count + 4))
        message.writeBytes(body)
        return message.bytes
    }

    private static func appendParse(to writer: inout ByteWriter,
                                    statement: String,
                                    query: String,
                                    parameterTypeOIDs: [Int32] = []) throws {
        guard parameterTypeOIDs.count <= 65535 else {
            throw PerunError.tooManyParameters(count: parameterTypeOIDs.count)
        }
        appendFrame(to: &writer, tag: "P") { body in
            appendParseBody(to: &body, statement: statement, query: query, parameterTypeOIDs: parameterTypeOIDs)
        }
    }

    private static func appendParseBody(to writer: inout ByteWriter,
                                        statement: String,
                                        query: String,
                                        parameterTypeOIDs: [Int32]) {
        writer.writeCString(statement)
        writer.writeCString(query)
        writer.writeInt16(Int16(bitPattern: UInt16(parameterTypeOIDs.count)))
        for oid in parameterTypeOIDs { writer.writeInt32(oid) }
    }

    private static func appendBind(to writer: inout ByteWriter,
                                   portal: String,
                                   statement: String,
                                   parameters: [(any PostgresEncodable)?],
                                   resultFormat: PostgresFormat) throws {
        guard parameters.count <= 65535 else {
            throw PerunError.tooManyParameters(count: parameters.count)
        }
        appendFrame(to: &writer, tag: "B") { body in
            appendBindBody(to: &body,
                           portal: portal,
                           statement: statement,
                           parameters: parameters,
                           resultFormat: resultFormat)
        }
    }

    private static func appendBindBody(to writer: inout ByteWriter,
                                       portal: String,
                                       statement: String,
                                       parameters: [(any PostgresEncodable)?],
                                       resultFormat: PostgresFormat) {
        writer.writeCString(portal)
        writer.writeCString(statement)
        writer.writeInt16(0)                                             // parameter format codes: all text
        writer.writeInt16(Int16(bitPattern: UInt16(parameters.count)))   // parameter values
        for parameter in parameters {
            if let text = parameter?.postgresText {
                writer.writeInt32(Int32(text.utf8.count))
                writer.writeString(text)
            } else {
                writer.writeInt32(-1)                 // SQL NULL
            }
        }
        // Result format codes: one code applied to all columns. Zero codes would
        // also mean "all text"; we send an explicit single code either way.
        if resultFormat == .binary {
            writer.writeInt16(1)
            writer.writeInt16(1)                      // 1 = binary, for every column
        } else {
            writer.writeInt16(0)                      // all text
        }
    }

    private static func appendDescribe(to writer: inout ByteWriter, _ target: StatementOrPortal, name: String) {
        appendFrame(to: &writer, tag: "D") {
            $0.writeUInt8(target.tag)
            $0.writeCString(name)
        }
    }

    private static func appendExecute(to writer: inout ByteWriter, portal: String, maxRows: Int32 = 0) {
        appendFrame(to: &writer, tag: "E") {
            $0.writeCString(portal)
            $0.writeInt32(maxRows)
        }
    }

    private static func appendClose(to writer: inout ByteWriter, _ target: StatementOrPortal, name: String) {
        appendFrame(to: &writer, tag: "C") {
            $0.writeUInt8(target.tag)
            $0.writeCString(name)
        }
    }

    private static func appendSync(to writer: inout ByteWriter) {
        appendFrame(to: &writer, tag: "S") { _ in }
    }

    private static func appendFrame(to writer: inout ByteWriter,
                                    tag: Character,
                                    writeBody: (inout ByteWriter) -> Void) {
        let lengthOffset = writer.beginFrame(tag: tag.asciiValue!)
        writeBody(&writer)
        writer.endFrame(lengthOffset: lengthOffset)
    }

    private static func estimatedExtendedQueryCapacity(query: String,
                                                       statement: String,
                                                       parameters: [(any PostgresEncodable)?]) -> Int {
        var capacity = query.utf8.count + statement.utf8.count + 64
        capacity += parameters.count * 16
        return capacity
    }
}
