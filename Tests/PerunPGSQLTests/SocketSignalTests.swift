import XCTest
@testable import PerunPGSQL

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Writing to a socket whose peer has gone away must fail with an error — never deliver SIGPIPE and
/// kill the whole process. `SystemSocket.sendAll` relies on `MSG_NOSIGNAL` (Linux) and `SO_NOSIGPIPE`
/// (Darwin, set in `makeConnected`) for that. This exercises the real send path over a socketpair
/// with a closed peer: reaching *any* assertion at all proves no signal killed the test runner.
final class SocketSignalTests: XCTestCase {

    func testSendToClosedPeerFailsInsteadOfRaisingSIGPIPE() throws {
        #if canImport(Darwin)
        let streamType = SOCK_STREAM
        #else
        let streamType = Int32(SOCK_STREAM.rawValue)
        #endif

        var fds: [Int32] = [-1, -1]
        let created = fds.withUnsafeMutableBufferPointer { socketpair(AF_UNIX, streamType, 0, $0.baseAddress) }
        precondition(created == 0, "socketpair() failed")
        let writer = fds[0], reader = fds[1]
        defer { close(writer) }

        #if canImport(Darwin)
        // No MSG_NOSIGNAL on Darwin — sendAll depends on the socket carrying SO_NOSIGPIPE, which
        // makeConnected sets. Set it here so this is a faithful stand-in for a real driver socket.
        var on: Int32 = 1
        setsockopt(writer, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif

        close(reader)   // the peer is gone; the next write gets EPIPE (and SIGPIPE, if unguarded)

        // Large enough that the write genuinely reaches the closed peer rather than sitting in a buffer.
        let payload = [UInt8](repeating: 0x41, count: 64 * 1024)
        XCTAssertThrowsError(try SystemSocket.sendAll(fd: writer, payload)) { error in
            guard case SocketError.sendFailed = error else {
                return XCTFail("expected SocketError.sendFailed, got \(error)")
            }
        }
    }
}
