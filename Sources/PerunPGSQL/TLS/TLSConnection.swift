import COpenSSL

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A TLS channel layered over an already-connected socket, backed by OpenSSL.
///
/// It is owned exclusively by one `PostgresConnection` and only ever touched
/// from that connection's serial I/O queue, so its mutable OpenSSL state is in
/// practice isolated — hence the `@unchecked Sendable`.
final class TLSConnection: @unchecked Sendable {
    private let ssl: OpaquePointer
    private let ctx: OpaquePointer

    private init(ssl: OpaquePointer, ctx: OpaquePointer) {
        self.ssl = ssl
        self.ctx = ctx
    }

    /// Perform the TLS handshake over `fd`. With `verifyFull`, the server's
    /// certificate chain and hostname are validated against the system trust
    /// store; otherwise the channel is encrypted but unauthenticated.
    static func connect(fd: Int32, hostname: String, verifyFull: Bool) throws -> TLSConnection {
        guard let method = TLS_client_method(), let ctx = SSL_CTX_new(method) else {
            throw PerunError.tlsHandshakeFailed("SSL_CTX_new failed: \(opensslErrors())")
        }
        _ = perun_SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION)

        if verifyFull {
            SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, nil)
            SSL_CTX_set_default_verify_paths(ctx)
        }

        guard let ssl = SSL_new(ctx) else {
            SSL_CTX_free(ctx)
            throw PerunError.tlsHandshakeFailed("SSL_new failed: \(opensslErrors())")
        }
        SSL_set_fd(ssl, fd)
        _ = hostname.withCString { perun_SSL_set_tlsext_host_name(ssl, $0) }   // SNI
        if verifyFull {
            _ = hostname.withCString { SSL_set1_host(ssl, $0) }
        }

        let handshake = SSL_connect(ssl)
        if handshake != 1 {
            let code = SSL_get_error(ssl, handshake)
            let detail = opensslErrors()
            SSL_free(ssl)
            SSL_CTX_free(ctx)
            throw PerunError.tlsHandshakeFailed("SSL_connect failed (error \(code)): \(detail)")
        }

        if verifyFull {
            let result = SSL_get_verify_result(ssl)
            guard result == X509_V_OK else {
                SSL_free(ssl)
                SSL_CTX_free(ctx)
                throw PerunError.tlsHandshakeFailed("certificate verification failed (code \(result))")
            }
        }

        return TLSConnection(ssl: ssl, ctx: ctx)
    }

    func send(_ bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        try bytes.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            var sent = 0
            while sent < bytes.count {
                let written = SSL_write(ssl, base + sent, Int32(bytes.count - sent))
                if written <= 0 {
                    throw PerunError.tlsIO("SSL_write failed (error \(SSL_get_error(ssl, written)))")
                }
                sent += Int(written)
            }
        }
    }

    func receive(maxLength: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let read = buffer.withUnsafeMutableBytes { raw in
            SSL_read(ssl, raw.baseAddress, Int32(maxLength))
        }
        if read > 0 {
            buffer.removeLast(maxLength - Int(read))
            return buffer
        }
        if read == 0 { return [] }                                  // clean EOF
        let code = SSL_get_error(ssl, read)
        if code == SSL_ERROR_ZERO_RETURN { return [] }              // peer closed TLS
        throw PerunError.tlsIO("SSL_read failed (error \(code)): \(opensslErrors())")
    }

    func close() {
        SSL_shutdown(ssl)
        SSL_free(ssl)
        SSL_CTX_free(ctx)
    }
}

/// Drain OpenSSL's per-thread error queue into a readable string.
func opensslErrors() -> String {
    var messages: [String] = []
    while true {
        let code = ERR_get_error()
        if code == 0 { break }
        var buffer = [CChar](repeating: 0, count: 256)
        ERR_error_string_n(code, &buffer, buffer.count)
        let utf8 = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        messages.append(String(decoding: utf8, as: UTF8.self))
    }
    return messages.isEmpty ? "(no OpenSSL error detail)" : messages.joined(separator: "; ")
}
