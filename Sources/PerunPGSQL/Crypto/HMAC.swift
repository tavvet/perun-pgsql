/// HMAC-SHA-256 (RFC 2104) built on our `SHA256`.
enum HMACSHA256 {
    static func authenticate(key: [UInt8], message: [UInt8]) -> [UInt8] {
        Context(key: key).authenticate(message: message)
    }

    struct Context {
        private let outerPad: [UInt8]
        private let innerPad: [UInt8]

        init(key: [UInt8]) {
            var block = key
            if block.count > SHA256.blockSize {
                block = SHA256.hash(block)
            }
            if block.count < SHA256.blockSize {
                block.append(contentsOf: [UInt8](repeating: 0, count: SHA256.blockSize - block.count))
            }

            outerPad = block.map { $0 ^ 0x5c }
            innerPad = block.map { $0 ^ 0x36 }
        }

        func authenticate(message: [UInt8]) -> [UInt8] {
            var innerInput = innerPad
            innerInput.reserveCapacity(innerPad.count + message.count)
            innerInput.append(contentsOf: message)
            let inner = SHA256.hash(innerInput)

            var outerInput = outerPad
            outerInput.reserveCapacity(outerPad.count + inner.count)
            outerInput.append(contentsOf: inner)
            return SHA256.hash(outerInput)
        }
    }
}
