/// PBKDF2 with HMAC-SHA-256 as the PRF (RFC 8018). SCRAM uses it to stretch the
/// password into the salted key.
enum PBKDF2 {
    /// If `deadline` is set, the iteration loop checks it roughly every 1024 rounds and throws
    /// `PerunError.timedOut` once it passes. The iteration count is server-controlled and, in
    /// SCRAM, consumed before the server is authenticated — so an inflated count is a CPU-exhaustion
    /// DoS. The deadline keeps that CPU work bounded by the caller's budget (the connect deadline)
    /// rather than running to completion after the socket has already been torn down.
    static func deriveKey(password: [UInt8],
                          salt: [UInt8],
                          iterations: Int,
                          keyLength: Int = SHA256.digestSize,
                          deadline: ContinuousClock.Instant? = nil) throws -> [UInt8] {
        precondition(iterations >= 1, "PBKDF2 needs at least one iteration")
        let hLen = SHA256.digestSize
        let blockCount = (keyLength + hLen - 1) / hLen

        var derived = [UInt8]()
        derived.reserveCapacity(blockCount * hLen)
        let prf = HMACSHA256.Context(key: password)

        for blockIndex in 1 ... blockCount {
            // U1 = PRF(password, salt || INT_32_BE(blockIndex))
            var salted = salt
            salted.append(UInt8(truncatingIfNeeded: blockIndex >> 24))
            salted.append(UInt8(truncatingIfNeeded: blockIndex >> 16))
            salted.append(UInt8(truncatingIfNeeded: blockIndex >> 8))
            salted.append(UInt8(truncatingIfNeeded: blockIndex))

            var u = prf.authenticate(message: salted)
            var t = u
            if iterations > 1 {
                for iteration in 2 ... iterations {
                    if let deadline, iteration & 0x3FF == 0, ContinuousClock().now >= deadline {
                        throw PerunError.timedOut
                    }
                    u = prf.authenticate(message: u)
                    for i in 0 ..< hLen { t[i] ^= u[i] }
                }
            }
            derived.append(contentsOf: t)
        }

        return Array(derived.prefix(keyLength))
    }
}
