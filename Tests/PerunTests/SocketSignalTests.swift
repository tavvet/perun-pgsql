import XCTest
@testable import PerunPGSQL

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Regression guard for the Linux-only SIGPIPE process-kill: OpenSSL's `SSL_write` does a plain
/// `write()` with no `MSG_NOSIGNAL`, and Linux has no `SO_NOSIGPIPE`, so a peer reset mid-write
/// used to terminate the whole process. `SystemSocket.ignoreSIGPIPE()` neutralises that. If the
/// protection ever regresses, the `write` below raises SIGPIPE and takes this test *runner* down —
/// a hard, unmissable failure rather than a silent one.
final class SocketSignalTests: XCTestCase {

    func testWriteToClosedPeerReturnsEPIPEInsteadOfKillingTheProcess() {
        SystemSocket.ignoreSIGPIPE()          // normally armed by makeConnected on first connect

        #if canImport(Darwin)
        let streamType = SOCK_STREAM
        #else
        let streamType = Int32(SOCK_STREAM.rawValue)
        #endif

        var fds = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, streamType, 0, &fds), 0, "socketpair failed")
        close(fds[1])                          // the peer is gone

        let payload = [UInt8](repeating: 0x41, count: 1024)
        let written = payload.withUnsafeBytes { write(fds[0], $0.baseAddress, $0.count) }

        // Merely reaching this line proves SIGPIPE did not kill us. The write itself must fail
        // with EPIPE rather than pretending to succeed.
        XCTAssertEqual(written, -1, "write to a closed peer should fail, not succeed")
        XCTAssertEqual(errno, EPIPE, "expected EPIPE (\(EPIPE)), got errno \(errno)")

        close(fds[0])
    }
}
