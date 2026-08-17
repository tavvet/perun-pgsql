import XCTest
@testable import PerunPGSQL

/// LISTEN/NOTIFY delivery, covering the regression where a notification arriving during a
/// `prepare()` round trip was dropped by `readPrepareResult` instead of reaching `notifications`.
final class NotificationIntegrationTests: XCTestCase {

    func testNotificationArrivingDuringPrepareIsDelivered() async throws {
        let listener = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await listener.close() } }
        let notifier = try await PostgresConnection.connect(integrationConfiguration())
        defer { Task { try? await notifier.close() } }

        try await listener.listen(to: "perun_prepare_chan")

        // Consume the listener's stream from a task, started before the notify so nothing is missed.
        let firstNotification = Task { () -> PostgresNotification? in
            for await note in listener.notifications { return note }
            return nil
        }

        // The listener is idle (not reading), so the server buffers this NOTIFY on its socket.
        _ = try await notifier.query("NOTIFY perun_prepare_chan, 'hello'")
        try await Task.sleep(for: .milliseconds(150))   // let the server deliver it to the listener's socket

        // prepare()'s first read consumes the buffered NotificationResponse; readPrepareResult must
        // yield it to `notifications` rather than dropping it via its default arm.
        _ = try await listener.prepare("SELECT 1")

        let note = try await withTimeout(.seconds(3)) { await firstNotification.value }
        XCTAssertEqual(note?.channel, "perun_prepare_chan")
        XCTAssertEqual(note?.payload, "hello")
    }

    // MARK: - Helpers

}
