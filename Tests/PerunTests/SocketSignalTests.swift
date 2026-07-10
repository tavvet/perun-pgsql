#if canImport(Glibc) || canImport(Musl)
import XCTest
@testable import PerunPGSQL

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Linux has no `SO_NOSIGPIPE`, so OpenSSL's writing calls (SSL_connect / SSL_write / SSL_shutdown)
/// are shielded by a thread-scoped SIGPIPE block (`withSIGPIPEBlocked`) instead of a process-wide
/// `signal()`. This proves the write is protected (EPIPE, not a process kill) and — crucially for a
/// library — that the thread's signal mask is left exactly as it was, leaking no global signal state.
/// (Darwin needs no equivalent: `SO_NOSIGPIPE` on the fd covers OpenSSL's writes, so the helper there
/// is a plain passthrough and this test is Linux-only.)
final class SocketSignalTests: XCTestCase {

    func testThreadScopedBlockShieldsWriteWithoutLeakingSignalState() {
        var fds = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds), 0, "socketpair failed")
        close(fds[1])                       // peer gone: a raw write here would raise SIGPIPE and kill us

        let payload = [UInt8](repeating: 0x41, count: 1024)
        let written = withSIGPIPEBlocked {
            payload.withUnsafeBytes { write(fds[0], $0.baseAddress, $0.count) }
        }
        close(fds[0])

        // Reaching this line at all means SIGPIPE did not kill the test runner.
        XCTAssertEqual(written, -1, "write to a closed peer should fail with EPIPE")
        XCTAssertEqual(errno, EPIPE, "expected EPIPE (\(EPIPE)), got errno \(errno)")

        // The helper must restore the thread's signal mask — SIGPIPE must not be left blocked.
        var mask = sigset_t()
        sigemptyset(&mask)
        pthread_sigmask(SIG_BLOCK, nil, &mask)
        XCTAssertEqual(sigismember(&mask, SIGPIPE), 0, "SIGPIPE mask leaked — helper did not restore it")
    }
}
#endif
