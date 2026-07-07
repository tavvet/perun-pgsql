/// Lowercase hex encoding without a Foundation dependency.
func hexEncode(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out = [UInt8]()
    out.reserveCapacity(bytes.count * 2)
    for byte in bytes {
        out.append(digits[Int(byte >> 4)])
        out.append(digits[Int(byte & 0x0f)])
    }
    return String(decoding: out, as: UTF8.self)
}
