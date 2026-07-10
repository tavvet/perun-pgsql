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

    /// Resolve `host`/`port` and open a connected TCP socket, returning its fd. `timeoutMilliseconds`
    /// bounds each address's connect attempt (nil = wait indefinitely, the OS default).
    static func makeConnected(host: String, port: UInt16, timeoutMilliseconds: Int32?) throws -> Int32 {
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

            if let failure = establish(fd: fd,
                                       to: info.pointee.ai_addr,
                                       length: info.pointee.ai_addrlen,
                                       timeoutMilliseconds: timeoutMilliseconds) {
                lastReason = failure          // try the next address, if any
                close(fd)
                candidate = info.pointee.ai_next
            } else {
                return fd
            }
        }
        throw SocketError.connectionFailed(host: host, port: port, reason: lastReason)
    }

    /// Drive a single `connect` to completion with a bounded wait. The socket is switched to
    /// non-blocking so a black-holed SYN can't park the I/O thread for the OS default (~130 s on
    /// Linux); we then `poll` for writability up to `timeoutMilliseconds` (nil = wait indefinitely)
    /// and read `SO_ERROR` for the real verdict. Returns `nil` on success (and restores blocking
    /// mode, which the rest of the layer expects), or a human-readable reason on failure.
    private static func establish(fd: Int32,
                                  to address: UnsafeMutablePointer<sockaddr>?,
                                  length: socklen_t,
                                  timeoutMilliseconds: Int32?) -> String? {
        let originalFlags = fcntl(fd, F_GETFL, 0)
        if originalFlags >= 0 { _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) }

        if connect(fd, address, length) == 0 {
            restoreBlocking(fd, originalFlags)
            return nil                                  // connected at once (typically loopback)
        }
        guard errno == EINPROGRESS || errno == EINTR else {
            return errnoString(errno)                   // immediate, hard failure (e.g. refused)
        }

        var pfd = pollfd()
        pfd.fd = fd
        pfd.events = Int16(POLLOUT)
        let deadline = timeoutMilliseconds.map { monotonicMillis() + Int64($0) }
        while true {
            let waitMillis: Int32
            if let deadline {
                let remaining = deadline - monotonicMillis()
                if remaining <= 0 { return "timed out after \(timeoutMilliseconds ?? 0) ms" }
                waitMillis = remaining > Int64(Int32.max) ? Int32.max : Int32(remaining)
            } else {
                waitMillis = -1                         // no deadline: block until writable
            }
            let ready = poll(&pfd, nfds_t(1), waitMillis)
            if ready < 0 {
                if errno == EINTR { continue }          // interrupted — keep waiting
                return errnoString(errno)
            }
            if ready == 0 { return "timed out after \(timeoutMilliseconds ?? 0) ms" }

            // Writable now, but the async connect may still have failed — SO_ERROR is the verdict.
            var soError: Int32 = 0
            var soLength = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soLength) < 0 {
                return errnoString(errno)
            }
            if soError != 0 { return errnoString(soError) }
            restoreBlocking(fd, originalFlags)
            return nil                                  // connected
        }
    }

    /// Return `fd` to the blocking mode the rest of the socket layer assumes.
    private static func restoreBlocking(_ fd: Int32, _ originalFlags: Int32) {
        if originalFlags >= 0 { _ = fcntl(fd, F_SETFL, originalFlags) }
    }

    /// Milliseconds from a monotonic clock — safe for measuring elapsed time (never steps backwards).
    private static func monotonicMillis() -> Int64 {
        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC, &now)
        return Int64(now.tv_sec) * 1000 + Int64(now.tv_nsec) / 1_000_000
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
