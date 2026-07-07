/// The authentication request carried by an `Authentication` ('R') message.
enum AuthenticationRequest: Sendable {
    case ok
    case cleartextPassword
    case md5Password(salt: [UInt8])
    case sasl(mechanisms: [String])
    case saslContinue(data: [UInt8])
    case saslFinal(data: [UInt8])
    case other(Int32)
}

/// One column's metadata from a `RowDescription` ('T') message.
struct FieldDescription: Sendable {
    let name: String
    let tableOID: Int32
    let columnAttributeNumber: Int16
    let dataTypeOID: Int32
    let dataTypeSize: Int16
    let typeModifier: Int32
    let formatCode: Int16       // 0 = text, 1 = binary
}

/// Transaction status reported by every `ReadyForQuery` ('Z') message.
enum TransactionStatus: Sendable, Equatable {
    case idle                   // 'I' — not in a transaction
    case inTransaction          // 'T'
    case inFailedTransaction    // 'E'
    case unknown(UInt8)

    init(byte: UInt8) {
        switch byte {
        case UInt8(ascii: "I"): self = .idle
        case UInt8(ascii: "T"): self = .inTransaction
        case UInt8(ascii: "E"): self = .inFailedTransaction
        default: self = .unknown(byte)
        }
    }
}

/// A decoded message from the server (the "backend").
enum BackendMessage: Sendable {
    case authentication(AuthenticationRequest)
    case parameterStatus(name: String, value: String)
    case backendKeyData(processID: Int32, secretKey: Int32)
    case readyForQuery(TransactionStatus)
    case rowDescription([FieldDescription])
    case dataRow([[UInt8]?])                    // nil element = SQL NULL
    case commandComplete(tag: String)
    case emptyQueryResponse
    case errorResponse(PostgresServerError)
    case noticeResponse(PostgresServerError)
    case parseComplete
    case bindComplete
    case closeComplete
    case noData
    case parameterDescription([Int32])
    case portalSuspended
    case notificationResponse(processID: Int32, channel: String, payload: String)
    /// A message type we don't handle yet — kept so the read loop can skip it.
    case unknown(tag: UInt8, payload: [UInt8])

    /// Decode one message body given its tag. `payload` excludes the tag and the
    /// 4 length bytes.
    static func decode(tag: UInt8, payload: [UInt8]) throws -> BackendMessage {
        var reader = ByteReader(payload)
        switch tag {
        case UInt8(ascii: "R"):
            return .authentication(try decodeAuthentication(&reader))

        case UInt8(ascii: "S"):
            let name = try reader.readCString()
            let value = try reader.readCString()
            return .parameterStatus(name: name, value: value)

        case UInt8(ascii: "K"):
            return .backendKeyData(processID: try reader.readInt32(),
                                   secretKey: try reader.readInt32())

        case UInt8(ascii: "Z"):
            return .readyForQuery(TransactionStatus(byte: try reader.readUInt8()))

        case UInt8(ascii: "T"):
            return .rowDescription(try decodeRowDescription(&reader))

        case UInt8(ascii: "D"):
            return .dataRow(try decodeDataRow(&reader))

        case UInt8(ascii: "C"):
            return .commandComplete(tag: try reader.readCString())

        case UInt8(ascii: "I"):
            return .emptyQueryResponse

        case UInt8(ascii: "E"):
            return .errorResponse(try decodeFields(&reader))

        case UInt8(ascii: "N"):
            return .noticeResponse(try decodeFields(&reader))

        case UInt8(ascii: "1"):
            return .parseComplete
        case UInt8(ascii: "2"):
            return .bindComplete
        case UInt8(ascii: "3"):
            return .closeComplete
        case UInt8(ascii: "n"):
            return .noData
        case UInt8(ascii: "s"):
            return .portalSuspended

        case UInt8(ascii: "t"):
            let count = try reader.readInt16()
            var oids: [Int32] = []
            oids.reserveCapacity(max(0, Int(count)))
            for _ in 0 ..< max(0, Int(count)) {
                oids.append(try reader.readInt32())
            }
            return .parameterDescription(oids)

        case UInt8(ascii: "A"):
            let pid = try reader.readInt32()
            let channel = try reader.readCString()
            let body = try reader.readCString()
            return .notificationResponse(processID: pid, channel: channel, payload: body)

        default:
            return .unknown(tag: tag, payload: payload)
        }
    }

    // MARK: - Field decoders

    private static func decodeAuthentication(
        _ reader: inout ByteReader
    ) throws -> AuthenticationRequest {
        let code = try reader.readInt32()
        switch code {
        case 0:
            return .ok
        case 3:
            return .cleartextPassword
        case 5:
            return .md5Password(salt: try reader.readBytes(4))
        case 10:
            var mechanisms: [String] = []
            while reader.remaining > 0 {
                let name = try reader.readCString()
                if name.isEmpty { break }
                mechanisms.append(name)
            }
            return .sasl(mechanisms: mechanisms)
        case 11:
            return .saslContinue(data: try reader.readBytes(reader.remaining))
        case 12:
            return .saslFinal(data: try reader.readBytes(reader.remaining))
        default:
            return .other(code)
        }
    }

    private static func decodeRowDescription(
        _ reader: inout ByteReader
    ) throws -> [FieldDescription] {
        let count = try reader.readInt16()
        var fields: [FieldDescription] = []
        fields.reserveCapacity(max(0, Int(count)))
        for _ in 0 ..< max(0, Int(count)) {
            fields.append(FieldDescription(
                name: try reader.readCString(),
                tableOID: try reader.readInt32(),
                columnAttributeNumber: try reader.readInt16(),
                dataTypeOID: try reader.readInt32(),
                dataTypeSize: try reader.readInt16(),
                typeModifier: try reader.readInt32(),
                formatCode: try reader.readInt16()
            ))
        }
        return fields
    }

    private static func decodeDataRow(_ reader: inout ByteReader) throws -> [[UInt8]?] {
        let count = try reader.readInt16()
        var columns: [[UInt8]?] = []
        columns.reserveCapacity(max(0, Int(count)))
        for _ in 0 ..< max(0, Int(count)) {
            let length = try reader.readInt32()
            if length < 0 {
                columns.append(nil)                     // SQL NULL
            } else {
                columns.append(try reader.readBytes(Int(length)))
            }
        }
        return columns
    }

    /// Shared decoder for ErrorResponse / NoticeResponse: a series of
    /// (type-byte, string) pairs terminated by a zero byte.
    private static func decodeFields(_ reader: inout ByteReader) throws -> PostgresServerError {
        var fields: [UInt8: String] = [:]
        while reader.remaining > 0 {
            let code = try reader.readUInt8()
            if code == 0 { break }
            fields[code] = try reader.readCString()
        }
        return PostgresServerError(fields: fields)
    }
}
