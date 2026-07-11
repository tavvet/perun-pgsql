#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Errors thrown by the low-level socket layer. Internal — `connect` maps these to
/// `PerunError.connectionFailed`, and steady-state I/O maps them to `PerunError.ioError`, so
/// callers only ever see `PerunError`.
enum SocketError: Error, CustomStringConvertible, Sendable {
    case resolutionFailed(host: String, port: UInt16, code: Int32)
    case connectionFailed(host: String, port: UInt16, reason: String)
    case sendFailed(errno: Int32)
    case receiveFailed(errno: Int32)

    public var description: String {
        switch self {
        case let .resolutionFailed(host, port, code):
            let msg = String(cString: gai_strerror(code))
            return "could not resolve \(host):\(port) — \(msg)"
        case let .connectionFailed(host, port, reason):
            return "could not connect to \(host):\(port) — \(reason)"
        case let .sendFailed(err):
            return "send() failed — \(errnoString(err))"
        case let .receiveFailed(err):
            return "recv() failed — \(errnoString(err))"
        }
    }
}

private func errnoString(_ code: Int32) -> String {
    "errno \(code): \(String(cString: strerror(code)))"
}

/// A thin, blocking wrapper over the POSIX socket API.
///
/// Everything here is a plain synchronous syscall. The blocking is intentional:
/// the connection actor runs these on a dedicated dispatch queue (see
/// `withBlockingIO`), so the Swift concurrency cooperative pool never blocks.
///
/// We deliberately operate on a bare file descriptor (`Int32`, which is
/// `Sendable`) rather than a class, so nothing non-`Sendable` ever crosses an
/// actor / continuation boundary.
enum SystemSocket {

    /// Resolve `host`/`port` and open a connected TCP socket, returning its fd. A non-nil
    /// `timeout` bounds each address's connect attempt (via a non-blocking connect + poll), so a
    /// blackholed host fails in bounded time instead of hanging on the OS default (~75 s); nil
    /// uses the OS default. The returned fd is left in blocking mode.
    static func makeConnected(host: String, port: UInt16, timeout: Duration?) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC          // IPv4 or IPv6
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        hints.ai_protocol = Int32(IPPROTO_TCP)

        var resolved: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &resolved)
        guard rc == 0, let head = resolved else {
            throw SocketError.resolutionFailed(host: host, port: port, code: rc)
        }
        defer { freeaddrinfo(head) }

        var lastReason = "no addresses returned"
        var candidate: UnsafeMutablePointer<addrinfo>? = head
        while let info = candidate {
            let fd = socket(info.pointee.ai_family,
                            info.pointee.ai_socktype,
                            info.pointee.ai_protocol)
            if fd < 0 {
                lastReason = errnoString(errno)
                candidate = info.pointee.ai_next
                continue
            }

            // On Darwin there is no MSG_NOSIGNAL send flag; instead we ask the
            // socket itself never to raise SIGPIPE when the peer goes away.
            #if canImport(Darwin)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on,
                       socklen_t(MemoryLayout<Int32>.size))
            #endif

            do {
                if try connectOne(fd: fd, address: info.pointee.ai_addr,
                                  length: info.pointee.ai_addrlen, timeout: timeout) {
                    return fd
                }
                lastReason = "timed out"
            } catch let error as SocketError {
                if case let .connectionFailed(_, _, reason) = error { lastReason = reason }
            }
            close(fd)
            candidate = info.pointee.ai_next
        }
        throw SocketError.connectionFailed(host: host, port: port, reason: lastReason)
    }

    /// Connect `fd` to one resolved address. With a `timeout`, uses a non-blocking connect and
    /// polls for completion, so the attempt can't outlast the deadline; the fd is returned to
    /// blocking mode either way. Returns false on timeout; throws on a connect error.
    private static func connectOne(fd: Int32,
                                   address: UnsafeMutablePointer<sockaddr>,
                                   length: socklen_t,
                                   timeout: Duration?) throws -> Bool {
        guard let timeout else {
            if connect(fd, address, length) == 0 { return true }
            throw SocketError.connectionFailed(host: "", port: 0, reason: errnoString(errno))
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }          // restore blocking mode for steady-state I/O

        if connect(fd, address, length) == 0 { return true }   // connected immediately (e.g. localhost)
        guard errno == EINPROGRESS else {
            throw SocketError.connectionFailed(host: "", port: 0, reason: errnoString(errno))
        }

        var pfd = pollfd(fd: fd, events: Int16(truncatingIfNeeded: POLLOUT), revents: 0)
        let ready: Int32 = {
            while true {
                let r = poll(&pfd, 1, pollTimeoutMillis(timeout))
                if r < 0 && errno == EINTR { continue }
                return r
            }
        }()
        guard ready > 0 else { return false }            // 0 = timed out; <0 = poll error → treat as failure

        var soError: Int32 = 0
        var errorLength = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &errorLength)
        guard soError == 0 else {
            throw SocketError.connectionFailed(host: "", port: 0, reason: errnoString(soError))
        }
        return true
    }

    /// A `Duration` as a `poll` timeout in whole milliseconds, clamped to `Int32` and ≥ 0.
    private static func pollTimeoutMillis(_ duration: Duration) -> Int32 {
        let (seconds, attoseconds) = duration.components
        let millis = seconds * 1000 + attoseconds / 1_000_000_000_000_000
        if millis <= 0 { return 0 }
        return millis > Int64(Int32.max) ? Int32.max : Int32(millis)
    }

    /// Write every byte of `bytes`, looping over partial writes.
    static func sendAll(fd: Int32, _ bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        try bytes.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            var sent = 0
            while sent < bytes.count {
                #if canImport(Darwin)
                let n = send(fd, base + sent, bytes.count - sent, 0)
                #else
                let n = send(fd, base + sent, bytes.count - sent, Int32(MSG_NOSIGNAL))
                #endif
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.sendFailed(errno: errno)
                }
                sent += n
            }
        }
    }

    /// Read up to `maxLength` bytes. Returns an empty array on a clean EOF
    /// (peer closed the connection).
    static func receive(fd: Int32, maxLength: Int) throws -> [UInt8] {
        var received = 0
        let buffer = [UInt8](unsafeUninitializedCapacity: maxLength) { raw, initializedCount in
            received = {
                while true {
                    let n = recv(fd, raw.baseAddress, maxLength, 0)
                    if n < 0 && errno == EINTR { continue }
                    return n
                }
            }()
            initializedCount = received > 0 ? received : 0
        }
        if received < 0 { throw SocketError.receiveFailed(errno: errno) }
        if received == 0 { return [] }          // EOF
        return buffer
    }

    /// Non-blocking liveness probe: peek one byte without consuming it. A fully-drained,
    /// quiescent connection has nothing waiting, so `EWOULDBLOCK`/`EAGAIN` (no data) means it is
    /// still open and healthy; `0` bytes is EOF (the peer closed).
    ///
    /// If a byte *is* waiting on a plaintext connection it is a backend message tag, and a
    /// pooled connection sits at a message boundary — so an unsolicited async message
    /// (NotificationResponse `A`, NoticeResponse `N`, ParameterStatus `S`) means the connection
    /// is healthy and the reader will consume it later, while anything else (typically a
    /// termination `ErrorResponse` `E`) means discard it. Over TLS the byte is ciphertext we
    /// can't classify, so any pending data is treated as suspect.
    static func isQuiescentOpen(fd: Int32, plaintextProtocol: Bool) -> Bool {
        var byte: UInt8 = 0
        while true {
            let n = withUnsafeMutablePointer(to: &byte) {
                recv(fd, $0, 1, Int32(MSG_PEEK) | Int32(MSG_DONTWAIT))
            }
            if n < 0 {
                if errno == EINTR { continue }
                return errno == EWOULDBLOCK || errno == EAGAIN   // no data waiting: quiescent and open
            }
            if n == 0 { return false }                            // EOF: the peer closed the socket
            guard plaintextProtocol else { return false }         // ciphertext: can't classify, so discard
            switch byte {
            case UInt8(ascii: "A"), UInt8(ascii: "N"), UInt8(ascii: "S"): return true
            default: return false
            }
        }
    }

    static func disconnect(fd: Int32) {
        close(fd)
    }

    /// Shut down both directions of the socket. Unlike `close`, this is safe to
    /// call from a *different* thread to interrupt a `recv` currently blocked on
    /// this fd — the blocked read returns instead of hanging forever.
    static func shutdownBoth(fd: Int32) {
        let shutRDWR: Int32 = 2     // SHUT_RDWR — the same value on every POSIX platform
        _ = shutdown(fd, shutRDWR)
    }
}
