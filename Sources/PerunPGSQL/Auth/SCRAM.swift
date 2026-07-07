/// Client side of the SCRAM-SHA-256 exchange (RFC 5802), as PostgreSQL uses it
/// for SASL authentication.
///
/// The flow is three round trips:
///   1. client-first  →  server-first   (nonce, salt, iteration count)
///   2. client-final   →  server-final   (proof  →  server signature)
///   3. server verifies the proof and replies AuthenticationOk
///
/// We use channel binding "n,," (not supported), which is correct until TLS
/// lands in a later milestone. Passwords are used as raw UTF-8; full SASLprep
/// (RFC 4013) normalization is a TODO and is the identity mapping for ASCII.
struct SCRAMClient {
    static let mechanism = "SCRAM-SHA-256"

    private let username: String
    private let password: [UInt8]
    private let clientNonce: String
    private var clientFirstBare = ""
    private var expectedServerSignature: [UInt8] = []
    private(set) var hasVerifiedServerSignature = false

    /// - Parameter username: value for the SCRAM `n=` field. PostgreSQL derives
    ///   the real username from the startup packet and ignores this, so it
    ///   defaults to empty; it exists mainly to reproduce RFC test vectors.
    init(username: String = "", password: String, clientNonce: String = SCRAMClient.makeNonce()) {
        self.username = username
        self.password = Array(password.utf8)
        self.clientNonce = clientNonce
    }

    /// Step 1: the client-first message, including the "n,," gs2 header.
    mutating func clientFirstMessage() -> String {
        clientFirstBare = "n=\(username),r=\(clientNonce)"
        return "n,,\(clientFirstBare)"
    }

    /// Step 2: consume server-first, produce client-final (with the proof).
    mutating func clientFinalMessage(serverFirst: String) throws -> String {
        let attributes = Self.parseAttributes(serverFirst)
        guard let combinedNonce = attributes["r"],
              let saltBase64 = attributes["s"],
              let iterationText = attributes["i"],
              let iterations = Int(iterationText),
              let salt = Base64.decode(saltBase64)
        else {
            throw PerunError.protocolViolation("malformed SCRAM server-first: \(serverFirst)")
        }
        guard combinedNonce.hasPrefix(clientNonce) else {
            throw PerunError.authenticationFailed("server nonce does not extend the client nonce")
        }

        let saltedPassword = PBKDF2.deriveKey(password: password,
                                              salt: salt,
                                              iterations: iterations,
                                              keyLength: 32)
        let clientKey = HMACSHA256.authenticate(key: saltedPassword, message: Array("Client Key".utf8))
        let storedKey = SHA256.hash(clientKey)

        // "c=biws" is Base64("n,,"), echoing our gs2 header with no binding.
        let clientFinalWithoutProof = "c=biws,r=\(combinedNonce)"
        let authMessage = Array("\(clientFirstBare),\(serverFirst),\(clientFinalWithoutProof)".utf8)

        let clientSignature = HMACSHA256.authenticate(key: storedKey, message: authMessage)
        var clientProof = clientKey
        for i in 0 ..< clientProof.count { clientProof[i] ^= clientSignature[i] }

        // Remember the server signature so we can authenticate the server too.
        let serverKey = HMACSHA256.authenticate(key: saltedPassword, message: Array("Server Key".utf8))
        expectedServerSignature = HMACSHA256.authenticate(key: serverKey, message: authMessage)
        hasVerifiedServerSignature = false

        return "\(clientFinalWithoutProof),p=\(Base64.encode(clientProof))"
    }

    /// Step 3: verify the server proved it also knows the password. This is what
    /// makes SCRAM mutually authenticating — a MITM without the password can't
    /// forge this signature.
    mutating func verifyServerFinal(_ serverFinal: String) throws {
        let attributes = Self.parseAttributes(serverFinal)
        if let errorText = attributes["e"] {
            throw PerunError.authenticationFailed("server rejected SCRAM: \(errorText)")
        }
        guard let signatureBase64 = attributes["v"],
              let signature = Base64.decode(signatureBase64)
        else {
            throw PerunError.protocolViolation("malformed SCRAM server-final: \(serverFinal)")
        }
        guard signature == expectedServerSignature else {
            throw PerunError.authenticationFailed("server signature mismatch (wrong password or MITM)")
        }
        hasVerifiedServerSignature = true
    }

    // MARK: - Helpers

    /// A fresh client nonce: 18 random bytes → 24 Base64 chars (no padding).
    /// All Base64 characters are valid SCRAM printable characters.
    static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(18)
        for _ in 0 ..< 18 { bytes.append(UInt8.random(in: 0 ... 255, using: &generator)) }
        return Base64.encode(bytes)
    }

    /// Parse a comma-separated `key=value` attribute list. SCRAM values never
    /// contain commas, and only the first `=` separates key from value (Base64
    /// values may contain `=` padding).
    static func parseAttributes(_ message: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in message.split(separator: ",", omittingEmptySubsequences: false) {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let key = String(part[part.startIndex ..< equals])
            let value = String(part[part.index(after: equals)...])
            result[key] = value
        }
        return result
    }
}
