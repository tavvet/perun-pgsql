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

        let handshake = withSIGPIPEBlocked { SSL_connect(ssl) }   // handshake writes; guard SIGPIPE
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
        // OpenSSL's write() carries no MSG_NOSIGNAL and Linux has no SO_NOSIGPIPE, so a peer reset
        // here would raise SIGPIPE. Block it on this thread for the whole send (a no-op on Darwin).
        try withSIGPIPEBlocked {
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
    }

    func receive(maxLength: Int) throws -> [UInt8] {
        var read: Int32 = 0
        let buffer = [UInt8](unsafeUninitializedCapacity: maxLength) { raw, initializedCount in
            // Not wrapped in withSIGPIPEBlocked: SSL_read only writes to the socket during a
            // renegotiation, which PostgreSQL never initiates (and TLS 1.3 removes) — so no SIGPIPE.
            read = SSL_read(ssl, raw.baseAddress, Int32(maxLength))
            initializedCount = read > 0 ? Int(read) : 0
        }
        if read > 0 {
            return buffer
        }
        if read == 0 { return [] }                                  // clean EOF
        let code = SSL_get_error(ssl, read)
        if code == SSL_ERROR_ZERO_RETURN { return [] }              // peer closed TLS
        throw PerunError.tlsIO("SSL_read failed (error \(code)): \(opensslErrors())")
    }

    func close() {
        _ = withSIGPIPEBlocked { SSL_shutdown(ssl) }   // writes close_notify — same SIGPIPE risk
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

/// Run `body` with SIGPIPE blocked on the current thread, draining a SIGPIPE it raises so the signal
/// can't fire when the mask is restored. OpenSSL's socket writes (`SSL_connect` / `SSL_write` /
/// `SSL_shutdown`) do a plain `write()`; on Linux there is no `SO_NOSIGPIPE`, so without this a peer
/// reset would kill the whole process. This shields the TLS write paths WITHOUT changing the
/// process-wide SIGPIPE disposition the host application owns (the approach libpq uses). On Darwin it
/// is a no-op: the socket already carries `SO_NOSIGPIPE`, which covers OpenSSL's writes too.
#if canImport(Glibc) || canImport(Musl)
func withSIGPIPEBlocked<T>(_ body: () throws -> T) rethrows -> T {
    var sigpipeOnly = sigset_t()
    sigemptyset(&sigpipeOnly)
    sigaddset(&sigpipeOnly, SIGPIPE)

    var pending = sigset_t()
    sigemptyset(&pending)
    sigpending(&pending)
    let alreadyPending = sigismember(&pending, SIGPIPE) == 1     // someone else's — never drain it

    var previousMask = sigset_t()
    pthread_sigmask(SIG_BLOCK, &sigpipeOnly, &previousMask)
    defer {
        if !alreadyPending {                                    // drain a SIGPIPE *we* raised…
            var nowPending = sigset_t()
            sigemptyset(&nowPending)
            sigpending(&nowPending)
            if sigismember(&nowPending, SIGPIPE) == 1 {
                var caught: Int32 = 0
                _ = sigwait(&sigpipeOnly, &caught)              // …returns at once: SIGPIPE is pending
            }
        }
        pthread_sigmask(SIG_SETMASK, &previousMask, nil)        // …then restore the thread's mask
    }
    return try body()
}
#else
@inline(__always)
func withSIGPIPEBlocked<T>(_ body: () throws -> T) rethrows -> T {
    try body()          // Darwin: SO_NOSIGPIPE on the fd already suppresses SIGPIPE for every write
}
#endif
