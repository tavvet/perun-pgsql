import Dispatch

/// Bridge a blocking POSIX call into async/await.
///
/// The body runs on `queue` (a dedicated, non-cooperative dispatch queue), so
/// the blocking `recv`/`send`/`connect` syscall never parks a thread from the
/// Swift concurrency cooperative pool. Only `Sendable` values (`Int32` fds,
/// `[UInt8]` buffers) are captured, so this stays clean under strict
/// concurrency checking.
func withBlockingIO<T: Sendable>(
    on queue: DispatchQueue,
    _ body: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        queue.async {
            do {
                continuation.resume(returning: try body())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
