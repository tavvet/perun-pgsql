import Dispatch
import XCTest
@testable import PerunPGSQL

/// The mutex behind the TLS engine's serialization. If it didn't actually serialize, concurrent
/// increments would lose updates and the final count would fall short.
final class POSIXLockTests: XCTestCase {

    private final class Counter: @unchecked Sendable { var value = 0 }

    func testSerializesConcurrentMutations() {
        let lock = POSIXLock()
        let counter = Counter()
        let iterations = 100_000
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            lock.withLock { counter.value += 1 }
        }
        XCTAssertEqual(counter.value, iterations)
    }
}
