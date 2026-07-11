import XCTest
@testable import PerunPGSQL

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

final class ConnectTimeoutBoundsTests: XCTestCase {

    func testConnectTimesOutWhenServerAcceptsButStaysSilent() async throws {
        // A peer that completes the TCP handshake and then sends nothing would block startup's
        // recv forever. The connect watchdog must bound the whole handshake, not just the TCP
        // connect, so this must fail promptly rather than hang.
        let server = try SilentServer()
        defer { server.stop() }

        let configuration = ConnectionConfiguration(host: "127.0.0.1", port: server.port,
                                                    user: "x", database: "x", tlsMode: .disable,
                                                    connectTimeout: .seconds(1))
        let start = ContinuousClock().now
        do {
            _ = try await PostgresConnection.connect(configuration)
            XCTFail("expected the connect to time out against a silent server")
        } catch let error as PerunError {
            // The watchdog shut the socket down; startup's parked recv surfaces one of these.
            switch error {
            case .connectionClosed, .ioError, .connectionFailed:
                break
            default:
                XCTFail("expected a connection failure, got \(error)")
            }
        } catch {
            XCTFail("expected a PerunError, got \(type(of: error)): \(error)")
        }
        XCTAssertLessThan(ContinuousClock().now - start, .seconds(5),
                          "the watchdog must bound the handshake, not only the TCP connect")
    }
}

/// A minimal TCP server that completes the handshake but never sends a byte. It only binds and
/// listens — it never `accept`s, so the kernel's listen backlog finishes the TCP connection while
/// no data ever comes back, which is exactly the "accepts then silent" case the watchdog must bound.
private final class SilentServer: @unchecked Sendable {
    let port: UInt16
    private let listenFd: Int32

    init() throws {
        #if canImport(Darwin)
        let streamType = SOCK_STREAM
        #else
        let streamType = Int32(SOCK_STREAM.rawValue)
        #endif
        let fd = socket(AF_INET, streamType, 0)          // a local, so the closures below don't capture self
        precondition(fd >= 0, "socket() failed")
        listenFd = fd
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                                        // ephemeral port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bindResult == 0, "bind() failed")
        precondition(listen(fd, 16) == 0, "listen() failed")

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        port = UInt16(bigEndian: bound.sin_port)
    }

    func stop() { close(listenFd) }
}
