/// PBKDF2 with HMAC-SHA-256 as the PRF (RFC 8018). SCRAM uses it to stretch the
/// password into the salted key.
enum PBKDF2 {
    static func deriveKey(password: [UInt8],
                          salt: [UInt8],
                          iterations: Int,
                          keyLength: Int = SHA256.digestSize) -> [UInt8] {
        precondition(iterations >= 1, "PBKDF2 needs at least one iteration")
        let hLen = SHA256.digestSize
        let blockCount = (keyLength + hLen - 1) / hLen

        var derived = [UInt8]()
        derived.reserveCapacity(blockCount * hLen)

        for blockIndex in 1 ... blockCount {
            // U1 = PRF(password, salt || INT_32_BE(blockIndex))
            var salted = salt
            salted.append(UInt8(truncatingIfNeeded: blockIndex >> 24))
            salted.append(UInt8(truncatingIfNeeded: blockIndex >> 16))
            salted.append(UInt8(truncatingIfNeeded: blockIndex >> 8))
            salted.append(UInt8(truncatingIfNeeded: blockIndex))

            var u = HMACSHA256.authenticate(key: password, message: salted)
            var t = u
            if iterations > 1 {
                for _ in 2 ... iterations {
                    u = HMACSHA256.authenticate(key: password, message: u)
                    for i in 0 ..< hLen { t[i] ^= u[i] }
                }
            }
            derived.append(contentsOf: t)
        }

        return Array(derived.prefix(keyLength))
    }
}
