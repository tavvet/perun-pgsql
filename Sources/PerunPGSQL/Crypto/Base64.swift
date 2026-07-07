/// Minimal standard Base64 (RFC 4648), no Foundation dependency. SCRAM carries
/// its salt, nonces and proofs as Base64 text.
enum Base64 {
    private static let alphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
    )

    static func encode(_ bytes: [UInt8]) -> String {
        var out = [UInt8]()
        out.reserveCapacity(((bytes.count + 2) / 3) * 4)

        var i = 0
        while i < bytes.count {
            let b0 = bytes[i]
            let b1 = i + 1 < bytes.count ? bytes[i + 1] : 0
            let b2 = i + 2 < bytes.count ? bytes[i + 2] : 0

            out.append(alphabet[Int(b0 >> 2)])
            out.append(alphabet[Int(((b0 & 0x03) << 4) | (b1 >> 4))])
            out.append(i + 1 < bytes.count ? alphabet[Int(((b1 & 0x0f) << 2) | (b2 >> 6))]
                                           : UInt8(ascii: "="))
            out.append(i + 2 < bytes.count ? alphabet[Int(b2 & 0x3f)]
                                           : UInt8(ascii: "="))
            i += 3
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func decode(_ string: String) -> [UInt8]? {
        var lookup = [Int8](repeating: -1, count: 256)
        for (index, char) in alphabet.enumerated() { lookup[Int(char)] = Int8(index) }

        var bytes = [UInt8]()
        var accumulator = 0
        var bitsInAccumulator = 0

        for char in string.utf8 {
            if char == UInt8(ascii: "=") { break }
            // Tolerate embedded whitespace / newlines.
            if char == 0x0a || char == 0x0d || char == 0x20 || char == 0x09 { continue }

            let value = lookup[Int(char)]
            if value < 0 { return nil }

            accumulator = (accumulator << 6) | Int(value)
            bitsInAccumulator += 6
            if bitsInAccumulator >= 8 {
                bitsInAccumulator -= 8
                bytes.append(UInt8((accumulator >> bitsInAccumulator) & 0xff))
            }
        }
        return bytes
    }
}
