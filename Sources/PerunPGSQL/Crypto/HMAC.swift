/// HMAC-SHA-256 (RFC 2104) built on our `SHA256`.
enum HMACSHA256 {
    static func authenticate(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var block = key
        if block.count > SHA256.blockSize {
            block = SHA256.hash(block)
        }
        if block.count < SHA256.blockSize {
            block.append(contentsOf: [UInt8](repeating: 0, count: SHA256.blockSize - block.count))
        }

        let outerPad = block.map { $0 ^ 0x5c }
        let innerPad = block.map { $0 ^ 0x36 }

        let inner = SHA256.hash(innerPad + message)
        return SHA256.hash(outerPad + inner)
    }
}
