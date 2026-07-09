/// Accumulates bytes in PostgreSQL wire order (network / big-endian).
///
/// The protocol is a stream of typed messages; a `ByteWriter` builds the body
/// of one message, and the framing code prefixes it with a length.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    init() {}

    init(reservingCapacity capacity: Int) {
        bytes.reserveCapacity(capacity)
    }

    mutating func reserveCapacity(_ capacity: Int) {
        bytes.reserveCapacity(capacity)
    }

    mutating func writeUInt8(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func writeInt16(_ value: Int16) {
        let u = UInt16(bitPattern: value)
        bytes.append(UInt8(truncatingIfNeeded: u >> 8))
        bytes.append(UInt8(truncatingIfNeeded: u))
    }

    mutating func writeInt32(_ value: Int32) {
        let u = UInt32(bitPattern: value)
        bytes.append(UInt8(truncatingIfNeeded: u >> 24))
        bytes.append(UInt8(truncatingIfNeeded: u >> 16))
        bytes.append(UInt8(truncatingIfNeeded: u >> 8))
        bytes.append(UInt8(truncatingIfNeeded: u))
    }

    mutating func writeBytes(_ value: [UInt8]) {
        bytes.append(contentsOf: value)
    }

    /// UTF-8 bytes of `string`, without a terminator.
    mutating func writeString(_ string: String) {
        bytes.append(contentsOf: string.utf8)
    }

    /// A C-style, NUL-terminated string, as PostgreSQL uses in many messages.
    mutating func writeCString(_ string: String) {
        bytes.append(contentsOf: string.utf8)
        bytes.append(0)
    }

    mutating func beginFrame(tag: UInt8) -> Int {
        writeUInt8(tag)
        let lengthOffset = bytes.count
        writeInt32(0)
        return lengthOffset
    }

    mutating func endFrame(lengthOffset: Int) {
        let length = bytes.count - lengthOffset
        patchInt32(Int32(length), at: lengthOffset)
    }

    private mutating func patchInt32(_ value: Int32, at offset: Int) {
        let u = UInt32(bitPattern: value)
        bytes[offset] = UInt8(truncatingIfNeeded: u >> 24)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: u >> 16)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: u >> 8)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: u)
    }
}

/// Reads big-endian values out of a message body, with bounds checking.
///
/// Every read is bounds-checked and throws `PerunError.protocolViolation` on
/// underflow, so a malformed/truncated server message surfaces as a clean error
/// rather than a crash.
struct ByteReader {
    private let bytes: ArraySlice<UInt8>
    private(set) var offset: Int

    init(_ bytes: [UInt8]) {
        self.init(bytes[...])
    }

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.offset = bytes.startIndex
    }

    var remaining: Int { bytes.endIndex - offset }

    private func requireRemaining(_ count: Int) throws {
        guard count >= 0, remaining >= count else {
            throw PerunError.protocolViolation(
                "unexpected end of message (needed \(count), have \(remaining))")
        }
    }

    mutating func readUInt8() throws -> UInt8 {
        try requireRemaining(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readInt16() throws -> Int16 {
        try requireRemaining(2)
        let value = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
        offset += 2
        return Int16(bitPattern: value)
    }

    mutating func readInt32() throws -> Int32 {
        try requireRemaining(4)
        let value = (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
        offset += 4
        return Int32(bitPattern: value)
    }

    mutating func readInt64() throws -> Int64 {
        try requireRemaining(8)
        var value: UInt64 = 0
        for _ in 0 ..< 8 {
            value = (value << 8) | UInt64(bytes[offset])
            offset += 1
        }
        return Int64(bitPattern: value)
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        try requireRemaining(count)
        let slice = Array(bytes[offset ..< offset + count])
        offset += count
        return slice
    }

    /// Read a NUL-terminated string; consumes the terminator.
    mutating func readCString() throws -> String {
        var scalarBytes: [UInt8] = []
        while true {
            let byte = try readUInt8()
            if byte == 0 { break }
            scalarBytes.append(byte)
        }
        return String(decoding: scalarBytes, as: UTF8.self)
    }
}
