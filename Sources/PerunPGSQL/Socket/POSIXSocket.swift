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

/// SIGPIPE would otherwise terminate the entire process the moment we write to a socket whose peer
/// has gone away. `sendAll` sets `MSG_NOSIGNAL` (Linux) and the socket carries `SO_NOSIGPIPE`
/// (Darwin), but OpenSSL's `SSL_write` issues a plain `write()` we don't flag — so on Linux a peer
/// reset mid-TLS-write would kill the host process (there is no `SO_NOSIGPIPE` there). Ignoring
/// SIGPIPE once, process-wide, closes that gap on every write path: a broken write then fails with
/// `EPIPE`, which surfaces as an ordinary I/O error. A global `let` initializer runs exactly once.
private let sigpipeIgnored: Void = {
    _ = signal(SIGPIPE, SIG_IGN)
}()

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

    /// Ignore SIGPIPE process-wide so a write to a dead peer can never kill us (see
    /// `sigpipeIgnored`). Idempotent and cheap: the work happens exactly once, however many
    /// connections open. Exposed so the regression test can arm it without opening a connection.
    static func ignoreSIGPIPE() {
        _ = sigpipeIgnored
    }

    /// Resolve `host`/`port` and open a connected TCP socket, returning its fd.
    static func makeConnected(host: String, port: UInt16) throws -> Int32 {
        ignoreSIGPIPE()          // a peer reset mid-write must never raise SIGPIPE and kill us
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

            if connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                return fd
            }
            lastReason = errnoString(errno)
            close(fd)
            candidate = info.pointee.ai_next
        }
        throw SocketError.connectionFailed(host: host, port: port, reason: lastReason)
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
    /// quiescent connection has nothing waiting, so `EWOULDBLOCK`/`EAGAIN` (no data) means
    /// it is still open and healthy. `0` bytes is EOF (the peer closed); any waiting bytes
    /// (the server sent something unsolicited — typically a termination `ErrorResponse`) or
    /// any other error means it should not be reused. For TLS this reads the raw socket,
    /// which still detects a closed peer and unexpected traffic at the TCP level.
    static func isQuiescentOpen(fd: Int32) -> Bool {
        var byte: UInt8 = 0
        while true {
            let n = withUnsafeMutablePointer(to: &byte) {
                recv(fd, $0, 1, Int32(MSG_PEEK) | Int32(MSG_DONTWAIT))
            }
            if n < 0 {
                if errno == EINTR { continue }
                return errno == EWOULDBLOCK || errno == EAGAIN
            }
            return false                        // 0 = EOF; >0 = unexpected pending data
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
