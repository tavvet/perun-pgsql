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
    /// A non-nil `timeout` bounds the *whole* connect — one monotonic deadline shared across every
    /// resolved address and every EINTR retry (via a non-blocking connect + poll), so a blackholed
    /// host fails within `timeout` instead of hanging on the OS default (~75 s) or stacking up to
    /// N × timeout across addresses; nil uses the OS default. The returned fd is left in blocking mode.
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

        // One monotonic deadline for the whole connect, shared across every resolved address and
        // every EINTR retry — otherwise a full `timeout` would be re-applied per address (up to
        // N × timeout) and re-armed on each signal (potentially forever). Saturating add, so a
        // huge timeout yields a far-future deadline instead of trapping on overflow.
        let deadline: Int64? = timeout.map { duration in
            let (sum, overflow) = monotonicMillis().addingReportingOverflow(durationMillis(duration))
            return overflow ? .max : sum
        }

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
                                  length: info.pointee.ai_addrlen, deadline: deadline) {
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

    /// Connect `fd` to one resolved address. With a `deadline` (monotonic ms), uses a non-blocking
    /// connect and polls for the remaining time until the deadline, so the whole connect can't
    /// outlast it; the fd is returned to blocking mode either way. Returns false on timeout; throws
    /// on a connect error.
    private static func connectOne(fd: Int32,
                                   address: UnsafeMutablePointer<sockaddr>,
                                   length: socklen_t,
                                   deadline: Int64?) throws -> Bool {
        guard let deadline else {
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
        while true {
            let remaining = deadline - monotonicMillis()
            if remaining <= 0 { return false }                       // deadline reached: timed out
            let wait = remaining > Int64(Int32.max) ? Int32.max : Int32(remaining)
            let r = poll(&pfd, 1, wait)
            if r < 0 {
                if errno == EINTR { continue }                       // retry against the *remaining* time
                return false
            }
            if r == 0 { return false }                               // poll hit the deadline
            break                                                    // the socket is writable
        }

        var soError: Int32 = 0
        var errorLength = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &errorLength)
        guard soError == 0 else {
            throw SocketError.connectionFailed(host: "", port: 0, reason: errnoString(soError))
        }
        return true
    }

    /// Milliseconds from a monotonic clock, for deadline math (immune to wall-clock changes).
    private static func monotonicMillis() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
    }

    /// A `Duration` as whole milliseconds, clamped to `[0, Int64.max]` with saturating arithmetic
    /// so an enormous duration (e.g. `.seconds(Int64.max)`) yields a practically-infinite timeout
    /// rather than trapping on overflow.
    private static func durationMillis(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0 else { return 0 }                             // negative timeout → no wait
        let (secondsMillis, mulOverflow) = seconds.multipliedReportingOverflow(by: 1000)
        if mulOverflow { return .max }
        let (total, addOverflow) = secondsMillis.addingReportingOverflow(attoseconds / 1_000_000_000_000_000)
        if addOverflow { return .max }
        return total < 0 ? 0 : total
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

    /// Non-blocking liveness probe: peek one byte without consuming it. Returns true only when the
    /// socket is quiescent and open — nothing is waiting (`EWOULDBLOCK`/`EAGAIN`). Any pending byte
    /// means it is *not* quiescent, so discard: on a pooled-idle connection no reader is running, so
    /// unsolicited data is either an async message the driver never consumed or a termination — and one
    /// peeked byte can neither tell them apart nor see what follows it (a benign `A` can shadow a
    /// trailing termination `E`; after a partly-buffered driver frame the next byte is mid-payload, not
    /// a message tag). Benign async messages the driver *did* buffer are already classified upstream by
    /// the readBuffer frame walk; here, at the raw socket, any byte is suspect. `0` bytes is EOF. This
    /// matches the TLS path, where pending ciphertext is likewise treated as not quiescent.
    static func isQuiescentOpen(fd: Int32) -> Bool {
        var byte: UInt8 = 0
        while true {
            let n = withUnsafeMutablePointer(to: &byte) {
                recv(fd, $0, 1, Int32(MSG_PEEK) | Int32(MSG_DONTWAIT))
            }
            if n < 0 {
                if errno == EINTR { continue }
                return errno == EWOULDBLOCK || errno == EAGAIN   // nothing waiting: quiescent and open
            }
            return false                                          // EOF, or unsolicited data we won't classify
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

/// A one-shot socket watchdog: after `duration`, shut `fd` down (both directions) to unblock a read or
/// write parked on it. The safety-critical discipline is `stop()` — **cancel and await** the timer
/// before closing the fd, so a late fire can never `shutdownBoth` a descriptor the OS has since reused
/// for another connection. Used wherever a blocking wire step needs a deadline: connect, the graceful
/// close Terminate, a TLS `CancelRequest`, and a copyOut resync drain.
struct SocketWatchdog {
    private let task: Task<Bool, Never>

    /// Arm the watchdog. `duration` is clamped to a non-negative span the sleep can represent, so a
    /// caller can pass a raw remaining-time (possibly negative) or an unbounded value without care.
    init(fd: Int32, after duration: Duration) {
        let capped = min(max(duration, .zero), .seconds(Int64(Int32.max)))
        task = Task {
            do { try await Task.sleep(for: capped) } catch { return false }   // cancelled: finished in time
            SystemSocket.shutdownBoth(fd: fd)
            return true                                                       // fired: the fd is shut down
        }
    }

    /// Stop the watchdog and report whether it already fired (shut the socket down). Awaits the timer,
    /// so once this returns the fd is safe to close.
    @discardableResult
    func stop() async -> Bool { task.cancel(); return await task.value }
}
