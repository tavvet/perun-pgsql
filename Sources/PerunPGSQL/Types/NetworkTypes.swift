import Foundation

// Codec for the network address types `inet` and `cidr`. Both share one wire shape — an
// address (4 bytes for IPv4, 16 for IPv6) plus a prefix length — differing only in the
// `isCIDR` flag (a `cidr` is a network, an `inet` is a host that may carry a netmask).

/// A PostgreSQL `inet` or `cidr` value: the raw address bytes, the prefix length, and whether
/// it is a `cidr`. `isIPv6` follows from the address length.
public struct PostgresInet: Sendable, Equatable {
    /// Address bytes: 4 for IPv4, 16 for IPv6.
    public var address: [UInt8]
    /// Netmask / prefix length, in bits.
    public var prefixLength: UInt8
    /// `true` for `cidr` (a network), `false` for `inet` (a host).
    public var isCIDR: Bool

    public var isIPv6: Bool { address.count == 16 }

    /// `prefixLength` defaults to the full address width (`/32` for IPv4, `/128` for IPv6).
    public init(address: [UInt8], prefixLength: UInt8? = nil, isCIDR: Bool = false) {
        self.address = address
        self.prefixLength = prefixLength ?? UInt8(address.count * 8)
        self.isCIDR = isCIDR
    }
}

// MARK: - Decoding

extension PostgresInet: PostgresDecodable {
    public static func decode(_ bytes: [UInt8], oid: Int32, format: PostgresFormat) throws -> PostgresInet {
        switch format {
        case .binary:
            // uint8 family, uint8 bits, uint8 is_cidr, uint8 address-length, then the address.
            var reader = ByteReader(bytes)
            _ = try reader.readUInt8()                       // family — inferred from the length instead
            let bits = try reader.readUInt8()
            let isCIDR = try reader.readUInt8() != 0
            let length = Int(try reader.readUInt8())
            guard length == 4 || length == 16 else { throw postgresDecodeError("inet", oid: oid, format: format, bytes) }
            let address = try reader.readBytes(length)
            return PostgresInet(address: address, prefixLength: bits, isCIDR: isCIDR)
        case .text:
            // Text can't tell inet from cidr on its own, so take that from the column's OID.
            guard let value = parsePostgresInet(utf8String(bytes), isCIDR: oid == PostgresOID.cidr) else {
                throw postgresDecodeError("inet", oid: oid, format: format, bytes)
            }
            return value
        }
    }
}

extension PostgresInet: PostgresArrayDecodable { public typealias ArrayScalar = PostgresInet }

// MARK: - Encoding

extension PostgresInet: PostgresEncodable {
    public var postgresText: String? {
        let full = UInt8(address.count * 8)
        let text = isIPv6 ? formatIPv6(address) : formatIPv4(address)
        // Show the prefix for a cidr, or for an inet that isn't a plain full-width host.
        return (isCIDR || prefixLength != full) ? "\(text)/\(prefixLength)" : text
    }

    public var postgresTypeOID: Int32 { isCIDR ? PostgresOID.cidr : PostgresOID.inet }

    public func postgresBinary() -> [UInt8]? {
        guard address.count == 4 || address.count == 16 else { return nil }
        let family: UInt8 = address.count == 4 ? 2 : 3      // PGSQL_AF_INET / PGSQL_AF_INET6
        return [family, prefixLength, isCIDR ? 1 : 0, UInt8(address.count)] + address
    }
}

// MARK: - Text parsing and formatting

/// Parse `inet`/`cidr` text: `192.168.1.5`, `10.0.0.0/8`, `2001:db8::1`, `::ffff:1.2.3.4/120`.
func parsePostgresInet(_ text: String, isCIDR: Bool) -> PostgresInet? {
    let parts = text.split(separator: "/", maxSplits: 1)
    let addressText = parts[0]
    let address: [UInt8]? = addressText.contains(":") ? parseIPv6(addressText) : parseIPv4(addressText)
    guard let address else { return nil }
    let prefix: UInt8?
    if parts.count == 2 {
        guard let value = UInt8(parts[1]), value <= UInt8(address.count * 8) else { return nil }
        prefix = value
    } else {
        prefix = nil
    }
    return PostgresInet(address: address, prefixLength: prefix, isCIDR: isCIDR)
}

/// Four dotted decimal octets → 4 bytes.
func parseIPv4(_ text: Substring) -> [UInt8]? {
    let octets = text.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4 else { return nil }
    var bytes: [UInt8] = []
    for octet in octets {
        guard let value = UInt8(octet) else { return nil }   // rejects >255 and non-digits
        bytes.append(value)
    }
    return bytes
}

/// Parse an IPv6 address, handling `::` zero-compression and a trailing embedded IPv4.
func parseIPv6(_ text: Substring) -> [UInt8]? {
    var body = String(text)

    // Rewrite a trailing embedded IPv4 (`…:1.2.3.4`) into two hex groups.
    if body.contains(".") {
        guard let lastColon = body.range(of: ":", options: .backwards)?.upperBound,
              let v4 = parseIPv4(body[lastColon...]) else { return nil }
        let high = String((UInt16(v4[0]) << 8) | UInt16(v4[1]), radix: 16)
        let low = String((UInt16(v4[2]) << 8) | UInt16(v4[3]), radix: 16)
        body = String(body[..<lastColon]) + high + ":" + low
    }

    func groups(_ segment: Substring) -> [UInt16]? {
        guard !segment.isEmpty else { return [] }
        var result: [UInt16] = []
        for part in segment.split(separator: ":", omittingEmptySubsequences: false) {
            guard part.count <= 4, let value = UInt16(part, radix: 16) else { return nil }
            result.append(value)
        }
        return result
    }

    let halves = body.components(separatedBy: "::")
    guard halves.count <= 2, let left = groups(Substring(halves[0])) else { return nil }

    let all: [UInt16]
    if halves.count == 2 {                                   // "::" fills the gap with zeros
        guard let right = groups(Substring(halves[1])) else { return nil }
        let fill = 8 - left.count - right.count
        guard fill >= 1 else { return nil }
        all = left + Array(repeating: 0, count: fill) + right
    } else {
        all = left
    }
    guard all.count == 8 else { return nil }

    var bytes: [UInt8] = []
    bytes.reserveCapacity(16)
    for group in all { bytes.append(UInt8(group >> 8)); bytes.append(UInt8(group & 0xFF)) }
    return bytes
}

private func formatIPv4(_ bytes: [UInt8]) -> String {
    bytes.map(String.init).joined(separator: ".")
}

/// Eight `:`-separated hex groups (not `::`-compressed). PostgreSQL accepts and canonicalizes it.
private func formatIPv6(_ bytes: [UInt8]) -> String {
    var groups: [String] = []
    var index = 0
    while index < bytes.count {
        groups.append(String((UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1]), radix: 16))
        index += 2
    }
    return groups.joined(separator: ":")
}
