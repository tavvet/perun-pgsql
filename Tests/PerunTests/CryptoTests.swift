import XCTest
@testable import PerunPGSQL

/// Correctness of the from-scratch crypto primitives, checked against published
/// test vectors (FIPS 180-4, RFC 1321, RFC 4231, RFC 7914, RFC 4648).
final class CryptoTests: XCTestCase {

    private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

    // MARK: SHA-256

    func testSHA256Vectors() {
        XCTAssertEqual(hexEncode(SHA256.hash(bytes(""))),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hexEncode(SHA256.hash(bytes("abc"))),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            hexEncode(SHA256.hash(bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testSHA256MultiBlock() {
        // 1,000,000 'a' → classic long vector; exercises many padding blocks.
        let million = [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000)
        XCTAssertEqual(hexEncode(SHA256.hash(million)),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    // MARK: MD5

    func testMD5Vectors() {
        XCTAssertEqual(MD5.hexDigest(bytes("")), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(MD5.hexDigest(bytes("abc")), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(MD5.hexDigest(bytes("The quick brown fox jumps over the lazy dog")),
                       "9e107d9d372bb6826bd81d3542a419d6")
        XCTAssertEqual(
            MD5.hexDigest(bytes("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")),
            "d174ab98d277d9f5a5611c2c9f419d9f")
    }

    // MARK: HMAC-SHA256 (RFC 4231)

    func testHMACSHA256() {
        // Test Case 2.
        let mac = HMACSHA256.authenticate(key: bytes("Jefe"),
                                          message: bytes("what do ya want for nothing?"))
        XCTAssertEqual(hexEncode(mac),
                       "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }

    // MARK: PBKDF2-HMAC-SHA256

    func testPBKDF2() throws {
        XCTAssertEqual(
            hexEncode(try PBKDF2.deriveKey(password: bytes("password"), salt: bytes("salt"),
                                       iterations: 1, keyLength: 32)),
            "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        XCTAssertEqual(
            hexEncode(try PBKDF2.deriveKey(password: bytes("password"), salt: bytes("salt"),
                                       iterations: 2, keyLength: 32)),
            "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
        XCTAssertEqual(
            hexEncode(try PBKDF2.deriveKey(password: bytes("password"), salt: bytes("salt"),
                                       iterations: 4096, keyLength: 32)),
            "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    }

    // MARK: Base64 (RFC 4648)

    func testBase64() {
        let cases: [(String, String)] = [
            ("", ""), ("f", "Zg=="), ("fo", "Zm8="), ("foo", "Zm9v"),
            ("foob", "Zm9vYg=="), ("fooba", "Zm9vYmE="), ("foobar", "Zm9vYmFy"),
        ]
        for (plain, encoded) in cases {
            XCTAssertEqual(Base64.encode(bytes(plain)), encoded, "encode \(plain)")
            XCTAssertEqual(Base64.decode(encoded), bytes(plain), "decode \(encoded)")
        }
    }
}
