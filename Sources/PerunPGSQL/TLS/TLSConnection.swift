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
/// An `SSL` object is **not** safe for concurrent use, yet a `PostgresConnection`
/// deliberately reads (on `readQueue`) and writes (on `ioQueue`) at the same time —
/// the background reader parks in a blocking read while callers keep sending. To make
/// that safe, the SSL engine is driven through in-memory BIOs instead of the socket:
///
///  - `SSL_read`/`SSL_write` move data to/from two memory BIOs. They never touch the
///    socket and never block, so they run under `engineLock` (serializing all access to
///    the one `SSL` object) without a parked reader ever holding the lock.
///  - The blocking socket syscalls that fill the read BIO and drain the write BIO happen
///    *outside* `engineLock`, each under its own lock (`socketReadLock` / `socketWriteLock`)
///    so ciphertext bytes can't interleave, but read and write still proceed concurrently.
///
/// The socket fd is owned by the `PostgresConnection`; this type reads and writes it but
/// never closes it. `@unchecked Sendable` because the locks provide the safety the
/// compiler can't see.
final class TLSConnection: @unchecked Sendable {
    private let ssl: OpaquePointer
    private let ctx: OpaquePointer
    private let rbio: OpaquePointer      // network → SSL: ciphertext we received, fed to SSL_read
    private let wbio: OpaquePointer      // SSL → network: ciphertext SSL produced, drained to the socket
    private let fd: Int32

    /// Serializes every call into the SSL state machine and its memory BIOs. Held only
    /// around non-blocking, in-memory work — never across a blocking socket syscall.
    private let engineLock = POSIXLock()
    /// Serializes blocking socket writes so two drains can't interleave ciphertext.
    private let socketWriteLock = POSIXLock()
    /// Serializes blocking socket reads so a writer's renegotiation read can't race the reader.
    private let socketReadLock = POSIXLock()
    private var closed = false

    private init(ssl: OpaquePointer, ctx: OpaquePointer, rbio: OpaquePointer, wbio: OpaquePointer, fd: Int32) {
        self.ssl = ssl
        self.ctx = ctx
        self.rbio = rbio
        self.wbio = wbio
        self.fd = fd
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
            // A failed trust-store load leaves an empty store, so verification fails closed
            // (rejects everything) rather than open — but surface it rather than proceed blind.
            guard SSL_CTX_set_default_verify_paths(ctx) == 1 else {
                SSL_CTX_free(ctx)
                throw PerunError.tlsHandshakeFailed("could not load the system trust store: \(opensslErrors())")
            }
        }

        guard let ssl = SSL_new(ctx),
              let rbio = BIO_new(BIO_s_mem()),
              let wbio = BIO_new(BIO_s_mem()) else {
            SSL_CTX_free(ctx)
            throw PerunError.tlsHandshakeFailed("SSL_new/BIO_new failed: \(opensslErrors())")
        }
        // SSL takes ownership of both BIOs; SSL_free releases them.
        SSL_set_bio(ssl, rbio, wbio)
        SSL_set_connect_state(ssl)
        // SNI names the target host for the server's virtual-host selection. RFC 6066 forbids IP
        // literals in the SNI HostName, and a strict server or proxy may reject a connection that
        // carries one — so send SNI only for DNS names. An IP host's identity is still bound below
        // through the IP-address verification path.
        if !isIPLiteral(hostname) {
            _ = hostname.withCString { perun_SSL_set_tlsext_host_name(ssl, $0) }   // SNI
        }
        if verifyFull {
            // Bind identity verification to the handshake. SSL_set1_host matches DNS names
            // (SAN/CN); an IP-literal host instead needs the IP-address path, or a certificate
            // with a valid IP SAN would be wrongly rejected. Failing to set it would silently
            // disable the check, so fail closed.
            let hostCheckConfigured: Bool
            if isIPLiteral(hostname) {
                hostCheckConfigured = hostname.withCString {
                    X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(ssl), $0) == 1
                }
            } else {
                hostCheckConfigured = hostname.withCString { SSL_set1_host(ssl, $0) == 1 }
            }
            guard hostCheckConfigured else {
                SSL_free(ssl)
                SSL_CTX_free(ctx)
                throw PerunError.tlsHandshakeFailed("host verification setup failed: \(opensslErrors())")
            }
        }

        do {
            try performHandshake(ssl: ssl, wbio: wbio, rbio: rbio, fd: fd)
        } catch {
            SSL_free(ssl)
            SSL_CTX_free(ctx)
            throw error
        }

        if verifyFull {
            let result = SSL_get_verify_result(ssl)
            guard result == X509_V_OK else {
                SSL_free(ssl)
                SSL_CTX_free(ctx)
                throw PerunError.tlsHandshakeFailed("certificate verification failed (code \(result))")
            }
        }

        return TLSConnection(ssl: ssl, ctx: ctx, rbio: rbio, wbio: wbio, fd: fd)
    }

    /// Drive `SSL_do_handshake` to completion, pumping ciphertext through the memory BIOs and
    /// the socket by hand. Runs single-threaded before the connection is shared, so no locks.
    private static func performHandshake(ssl: OpaquePointer, wbio: OpaquePointer,
                                         rbio: OpaquePointer, fd: Int32) throws {
        while true {
            let ret = SSL_do_handshake(ssl)
            if ret == 1 { return }
            let err = SSL_get_error(ssl, ret)
            try flushMemoryBIO(wbio, toSocket: fd)          // send whatever the handshake produced
            switch err {
            case SSL_ERROR_WANT_READ:
                guard try feedMemoryBIO(rbio, fromSocket: fd) else {
                    throw PerunError.tlsHandshakeFailed("server closed the connection during the TLS handshake")
                }
            case SSL_ERROR_WANT_WRITE:
                continue                                    // output already flushed; retry
            default:
                throw PerunError.tlsHandshakeFailed("SSL_connect failed (error \(err)): \(opensslErrors())")
            }
        }
    }

    // MARK: - Steady-state I/O

    func send(_ bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        var offset = 0
        while offset < bytes.count {
            switch encrypt(bytes, offset: offset) {
            case let .progressed(count):
                offset += count
            case .wantRead:
                // Renegotiation / TLS 1.3 KeyUpdate: SSL must read before it can write more.
                try drainOutgoing()
                guard try fillIncoming() else { throw PerunError.tlsIO("connection closed during TLS write") }
            case .wantWrite:
                try drainOutgoing()
            case let .failed(error):
                throw error
            }
            try drainOutgoing()
        }
    }

    func receive(maxLength: Int) throws -> [UInt8] {
        while true {
            switch decrypt(maxLength: maxLength) {
            case let .data(bytes):
                try drainOutgoing()                          // ship any post-handshake output produced as a side effect
                return bytes
            case .eof:
                return []
            case .wantRead:
                try drainOutgoing()
                guard try fillIncoming() else { return [] }   // clean EOF
            case .wantWrite:
                try drainOutgoing()
            case let .failed(error):
                throw error
            }
        }
    }

    func close() {
        engineLock.withLock {
            guard !closed else { return }
            closed = true
            SSL_shutdown(ssl)                                // best-effort close_notify (buffered in wbio, dropped)
            SSL_free(ssl)                                    // frees ssl and both BIOs
            SSL_CTX_free(ctx)
        }
    }

    // MARK: - SSL engine (under engineLock)

    private enum ReadOutcome { case data([UInt8]); case wantRead; case wantWrite; case eof; case failed(PerunError) }
    private enum WriteOutcome { case progressed(Int); case wantRead; case wantWrite; case failed(PerunError) }

    private func decrypt(maxLength: Int) -> ReadOutcome {
        engineLock.lock()
        defer { engineLock.unlock() }
        guard !closed else { return .failed(PerunError.tlsIO("TLS connection is closed")) }
        var read: Int32 = 0
        let buffer = [UInt8](unsafeUninitializedCapacity: maxLength) { raw, count in
            read = SSL_read(ssl, raw.baseAddress, Int32(maxLength))
            count = read > 0 ? Int(read) : 0
        }
        if read > 0 { return .data(buffer) }
        let err = SSL_get_error(ssl, read)
        switch err {
        case SSL_ERROR_WANT_READ: return .wantRead
        case SSL_ERROR_WANT_WRITE: return .wantWrite
        case SSL_ERROR_ZERO_RETURN: return .eof
        default: return .failed(PerunError.tlsIO("SSL_read failed (error \(err)): \(opensslErrors())"))
        }
    }

    private func encrypt(_ bytes: [UInt8], offset: Int) -> WriteOutcome {
        engineLock.lock()
        defer { engineLock.unlock() }
        guard !closed else { return .failed(PerunError.tlsIO("TLS connection is closed")) }
        // Cap a single SSL_write so a >2 GiB buffer can't overflow the Int32 length.
        let remaining = min(bytes.count - offset, 1 << 20)
        let written = bytes.withUnsafeBytes { raw -> Int32 in
            SSL_write(ssl, raw.baseAddress!.advanced(by: offset), Int32(remaining))
        }
        if written > 0 { return .progressed(Int(written)) }
        let err = SSL_get_error(ssl, written)
        switch err {
        case SSL_ERROR_WANT_READ: return .wantRead
        case SSL_ERROR_WANT_WRITE: return .wantWrite
        default: return .failed(PerunError.tlsIO("SSL_write failed (error \(err)): \(opensslErrors())"))
        }
    }

    // MARK: - Socket pump (outside engineLock)

    /// Move all pending ciphertext from the write BIO to the socket. Holds `socketWriteLock`
    /// across the whole drain so a concurrent drain can't reorder records on the wire.
    private func drainOutgoing() throws {
        try socketWriteLock.withLock {
            while true {
                var chunk: [UInt8] = []
                engineLock.withLock {
                    let pending = Int(BIO_ctrl_pending(wbio))
                    guard pending > 0 else { return }
                    let want = min(pending, 65_536)
                    chunk = [UInt8](unsafeUninitializedCapacity: want) { raw, count in
                        let n = BIO_read(wbio, raw.baseAddress, Int32(want))
                        count = n > 0 ? Int(n) : 0
                    }
                }
                if chunk.isEmpty { return }
                do { try SystemSocket.sendAll(fd: fd, chunk) }
                catch let error as SocketError { throw PerunError.tlsIO(error.description) }
            }
        }
    }

    /// Block for one chunk of ciphertext and feed it to the read BIO. Returns false on EOF.
    private func fillIncoming() throws -> Bool {
        let chunk: [UInt8]
        do { chunk = try socketReadLock.withLock { try SystemSocket.receive(fd: fd, maxLength: 65_536) } }
        catch let error as SocketError { throw PerunError.tlsIO(error.description) }
        guard !chunk.isEmpty else { return false }           // clean EOF
        engineLock.withLock {
            _ = chunk.withUnsafeBytes { BIO_write(rbio, $0.baseAddress, Int32(chunk.count)) }
        }
        return true
    }

    private static func flushMemoryBIO(_ bio: OpaquePointer, toSocket fd: Int32) throws {
        while true {
            let pending = Int(BIO_ctrl_pending(bio))
            guard pending > 0 else { return }
            let want = min(pending, 65_536)
            let chunk = [UInt8](unsafeUninitializedCapacity: want) { raw, count in
                let n = BIO_read(bio, raw.baseAddress, Int32(want))
                count = n > 0 ? Int(n) : 0
            }
            if chunk.isEmpty { return }
            do { try SystemSocket.sendAll(fd: fd, chunk) }
            catch let error as SocketError { throw PerunError.tlsHandshakeFailed(error.description) }
        }
    }

    private static func feedMemoryBIO(_ bio: OpaquePointer, fromSocket fd: Int32) throws -> Bool {
        let chunk: [UInt8]
        do { chunk = try SystemSocket.receive(fd: fd, maxLength: 65_536) }
        catch let error as SocketError { throw PerunError.tlsHandshakeFailed(error.description) }
        guard !chunk.isEmpty else { return false }
        _ = chunk.withUnsafeBytes { BIO_write(bio, $0.baseAddress, Int32(chunk.count)) }
        return true
    }
}

/// A minimal POSIX mutex wrapper, so the TLS layer stays Foundation-free. Heap-allocated
/// so the mutex has a stable address across `lock`/`unlock` calls.
final class POSIXLock: @unchecked Sendable {
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)

    init() { pthread_mutex_init(mutex, nil) }
    deinit { pthread_mutex_destroy(mutex); mutex.deallocate() }

    func lock() { pthread_mutex_lock(mutex) }
    func unlock() { pthread_mutex_unlock(mutex) }

    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// Whether `host` is a numeric IP literal (IPv4 or IPv6) rather than a DNS name — so TLS
/// verification uses the IP-address path instead of DNS-name matching.
private func isIPLiteral(_ host: String) -> Bool {
    var v4 = in_addr()
    if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return true }
    var v6 = in6_addr()
    if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 { return true }
    return false
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
